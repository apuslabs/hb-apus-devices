/*
 * NVIDIA GPU attestation NIF for sev_gpu@1.0.
 *
 * Wraps the C API of NVIDIA's attestation SDK (NVAT) for the Erlang module
 * dev_sev_gpu_nif. Both attestation calls run on dirty I/O schedulers.
 *
 *   collect_evidence/1  Collects GPU evidence through NVML for a hex nonce,
 *                       then attests the GPU with NVAT's local verifier.
 *                       Returns {ok, JSON} with verified, evidences, claims
 *                       and eat.
 *   verify_evidence/1   Attests already serialized GPU evidence with the
 *                       local verifier. The input is a JSON object with
 *                       nonce, evidences and scratch-dir. Returns {ok, JSON}
 *                       with verified, claims and eat.
 *   loaded/0            Returns true; the Erlang stub returns false.
 *
 * Errors are returned as {error, Binary} with NVAT's return-code string.
 */

#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unistd.h>

#include "erl_nif.h"
#include "nlohmann/json.hpp"
#include "nvat.h"

using json = nlohmann::json;

/* ============================================================================
 * RAII owners for NVAT handles
 * ============================================================================ */

template<class T> struct NvatDeleter;

template<> struct NvatDeleter<nvat_attestation_ctx_t> {
    void operator()(nvat_attestation_ctx_t* ptr) const {
        if (ptr) nvat_attestation_ctx_free(ptr);
    }
};

template<> struct NvatDeleter<nvat_sdk_opts_t> {
    void operator()(nvat_sdk_opts_t* ptr) const {
        if (ptr) nvat_sdk_opts_free(ptr);
    }
};

template<> struct NvatDeleter<nvat_gpu_evidence_source_t> {
    void operator()(nvat_gpu_evidence_source_t* ptr) const {
        if (ptr) nvat_gpu_evidence_source_free(ptr);
    }
};

template<> struct NvatDeleter<nvat_nonce_t> {
    void operator()(nvat_nonce_t* ptr) const {
        if (ptr) nvat_nonce_free(ptr);
    }
};

template<> struct NvatDeleter<nvat_str_t> {
    void operator()(nvat_str_t* ptr) const {
        if (ptr) nvat_str_free(ptr);
    }
};

template<> struct NvatDeleter<nvat_claims_collection_t> {
    void operator()(nvat_claims_collection_t* ptr) const {
        if (ptr) nvat_claims_collection_free(ptr);
    }
};

template<class T>
using nvat_ptr = std::unique_ptr<T, NvatDeleter<T>>;

/* GPU evidence array returned by nvat_gpu_evidence_collect. */
class GpuEvidenceArray {
public:
    nvat_gpu_evidence_t* evidences = nullptr;
    size_t num_evidences = 0;

    GpuEvidenceArray() = default;
    ~GpuEvidenceArray() {
        if (evidences) {
            nvat_gpu_evidence_array_free(&evidences, num_evidences);
        }
    }

    GpuEvidenceArray(const GpuEvidenceArray&) = delete;
    GpuEvidenceArray& operator=(const GpuEvidenceArray&) = delete;
};

/* A file that is removed when the owner goes out of scope. */
class ScratchFile {
public:
    std::string path;

    ScratchFile() = default;
    ~ScratchFile() {
        if (!path.empty()) unlink(path.c_str());
    }

    ScratchFile(const ScratchFile&) = delete;
    ScratchFile& operator=(const ScratchFile&) = delete;

    /* Create a fresh file in dir and write contents to it. */
    bool create(const std::string& dir, const std::string& contents) {
        std::string templ = dir + "/sev-gpu-evidence-XXXXXX.json";
        std::unique_ptr<char[]> buf(new char[templ.size() + 1]);
        std::memcpy(buf.get(), templ.c_str(), templ.size() + 1);
        int fd = mkstemps(buf.get(), 5);
        if (fd < 0) return false;
        path = buf.get();
        size_t offset = 0;
        while (offset < contents.size()) {
            ssize_t n = write(fd, contents.data() + offset, contents.size() - offset);
            if (n <= 0) {
                close(fd);
                return false;
            }
            offset += static_cast<size_t>(n);
        }
        return close(fd) == 0;
    }
};

/* ============================================================================
 * SDK lifecycle
 * ============================================================================ */

static std::mutex sdk_mutex;
static bool sdk_initialized = false;

static nvat_rc_t ensure_sdk_initialized() {
    std::lock_guard<std::mutex> lock(sdk_mutex);

    if (!sdk_initialized) {
        nvat_sdk_opts_t raw_opts = nullptr;
        nvat_rc_t err = nvat_sdk_opts_create(&raw_opts);
        if (err != NVAT_RC_OK) return err;

        nvat_ptr<nvat_sdk_opts_t> opts(&raw_opts);

        nvat_logger_t logger = nullptr;
#ifdef NVAT_DEBUG_LOG
        err = nvat_logger_spdlog_create(&logger, "dev_sev_gpu_nif", NVAT_LOG_LEVEL_DEBUG);
#else
        err = nvat_logger_spdlog_create(&logger, "dev_sev_gpu_nif", NVAT_LOG_LEVEL_ERROR);
#endif
        if (err == NVAT_RC_OK && logger) {
            nvat_sdk_opts_set_logger(*opts.get(), logger);
            nvat_logger_free(&logger);
        }

        err = nvat_sdk_init(*opts.get());
        if (err != NVAT_RC_OK) return err;

        sdk_initialized = true;
    }

    return NVAT_RC_OK;
}

/* ============================================================================
 * Term helpers
 * ============================================================================ */

static ERL_NIF_TERM make_atom(ErlNifEnv* env, const char* atom) {
    ERL_NIF_TERM ret;
    if (enif_make_existing_atom(env, atom, &ret, ERL_NIF_LATIN1)) {
        return ret;
    }
    return enif_make_atom(env, atom);
}

static ERL_NIF_TERM make_binary(ErlNifEnv* env, const std::string& str) {
    ERL_NIF_TERM bin;
    unsigned char* buf = enif_make_new_binary(env, str.size(), &bin);
    if (buf && !str.empty()) {
        std::memcpy(buf, str.data(), str.size());
    }
    return bin;
}

static ERL_NIF_TERM make_ok(ErlNifEnv* env, ERL_NIF_TERM result) {
    return enif_make_tuple2(env, make_atom(env, "ok"), result);
}

static ERL_NIF_TERM make_error(ErlNifEnv* env, const std::string& reason) {
    return enif_make_tuple2(env, make_atom(env, "error"), make_binary(env, reason));
}

static ERL_NIF_TERM make_rc_error(ErlNifEnv* env, nvat_rc_t err) {
    const char* text = nvat_rc_to_string(err);
    return make_error(env, text ? text : "NVAT error");
}

/* Parse a JSON document, or return the fallback value. */
static json parse_or(const std::string& text, const json& fallback) {
    try {
        return json::parse(text);
    } catch (...) {
        return fallback;
    }
}

/* ============================================================================
 * Attestation
 * ============================================================================ */

/* Create a GPU attestation context that uses the default evidence policy and
 * NVAT's local verifier. */
static nvat_rc_t make_local_gpu_ctx(nvat_ptr<nvat_attestation_ctx_t>& out_ctx,
                                    nvat_attestation_ctx_t& raw_ctx) {
    nvat_rc_t err = nvat_attestation_ctx_create(&raw_ctx);
    if (err != NVAT_RC_OK) return err;
    out_ctx.reset(&raw_ctx);

    err = nvat_attestation_ctx_set_device_type(raw_ctx, NVAT_DEVICE_GPU);
    if (err != NVAT_RC_OK) return err;

    nvat_evidence_policy_t raw_policy = nullptr;
    err = nvat_evidence_policy_create_default(&raw_policy);
    if (err != NVAT_RC_OK) return err;
    /* On success the context takes ownership of the policy. */
    err = nvat_attestation_ctx_set_evidence_policy(raw_ctx, &raw_policy);
    if (err != NVAT_RC_OK) {
        nvat_evidence_policy_free(&raw_policy);
        return err;
    }

    return nvat_attestation_ctx_set_verifier_type(raw_ctx, NVAT_VERIFY_LOCAL);
}

/* Attest with the context and add verified, claims and eat to result. The
 * claims and detached EAT are kept whenever NVAT produces them, including
 * when the overall verdict is negative. */
static void attest_into(nvat_attestation_ctx_t ctx, nvat_nonce_t nonce, json& result) {
    nvat_str_t raw_eat = nullptr;
    nvat_claims_collection_t raw_claims = nullptr;
    nvat_rc_t err = nvat_attest_device(ctx, nonce, &raw_eat, &raw_claims);

    nvat_ptr<nvat_str_t> eat(raw_eat ? &raw_eat : nullptr);
    nvat_ptr<nvat_claims_collection_t> claims(raw_claims ? &raw_claims : nullptr);

    result["verified"] = (err == NVAT_RC_OK);

    json claims_json = json::array();
    if (raw_claims) {
        nvat_str_t raw_claims_str = nullptr;
        if (nvat_claims_collection_serialize_json(raw_claims, &raw_claims_str) == NVAT_RC_OK) {
            nvat_ptr<nvat_str_t> claims_str(&raw_claims_str);
            char* claims_data = nullptr;
            if (nvat_str_get_data(raw_claims_str, &claims_data) == NVAT_RC_OK && claims_data) {
                claims_json = parse_or(claims_data, json::array());
            }
        }
    }
    result["claims"] = claims_json;

    json eat_json = nullptr;
    if (raw_eat) {
        char* eat_data = nullptr;
        if (nvat_str_get_data(raw_eat, &eat_data) == NVAT_RC_OK && eat_data) {
            eat_json = parse_or(eat_data, nullptr);
        }
    }
    result["eat"] = eat_json;
}

/* collect_evidence(Nonce) */
static ERL_NIF_TERM collect_evidence_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    nvat_rc_t err = ensure_sdk_initialized();
    if (err != NVAT_RC_OK) return make_rc_error(env, err);

    ErlNifBinary nonce_bin;
    if (!enif_inspect_binary(env, argv[0], &nonce_bin)) {
        return make_error(env, "nonce must be a binary");
    }
    std::string nonce_str(reinterpret_cast<char*>(nonce_bin.data), nonce_bin.size);

    nvat_nonce_t raw_nonce = nullptr;
    err = nvat_nonce_from_hex(&raw_nonce, nonce_str.c_str());
    if (err != NVAT_RC_OK) return make_rc_error(env, err);
    nvat_ptr<nvat_nonce_t> nonce(&raw_nonce);

    /* Collect evidence from the GPUs through NVML. */
    nvat_gpu_evidence_source_t raw_source = nullptr;
    err = nvat_gpu_evidence_source_nvml_create(&raw_source);
    if (err != NVAT_RC_OK) return make_rc_error(env, err);
    nvat_ptr<nvat_gpu_evidence_source_t> source(&raw_source);

    GpuEvidenceArray evidence;
    err = nvat_gpu_evidence_collect(raw_source, raw_nonce,
                                    &evidence.evidences, &evidence.num_evidences);
    if (err != NVAT_RC_OK) return make_rc_error(env, err);

    nvat_str_t raw_serialized = nullptr;
    err = nvat_gpu_evidence_serialize_json(evidence.evidences, evidence.num_evidences,
                                           &raw_serialized);
    if (err != NVAT_RC_OK) return make_rc_error(env, err);
    nvat_ptr<nvat_str_t> serialized(&raw_serialized);

    char* evidence_data = nullptr;
    err = nvat_str_get_data(raw_serialized, &evidence_data);
    if (err != NVAT_RC_OK) return make_rc_error(env, err);

    /* Attest the GPUs with the local verifier for the same nonce. */
    nvat_attestation_ctx_t raw_ctx = nullptr;
    nvat_ptr<nvat_attestation_ctx_t> ctx;
    err = make_local_gpu_ctx(ctx, raw_ctx);
    if (err != NVAT_RC_OK) return make_rc_error(env, err);

    json result;
    result["evidences"] = parse_or(evidence_data ? evidence_data : "", json::array());
    attest_into(raw_ctx, raw_nonce, result);

    return make_ok(env, make_binary(env, result.dump()));
}

/* verify_evidence(Request) */
static ERL_NIF_TERM verify_evidence_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    nvat_rc_t err = ensure_sdk_initialized();
    if (err != NVAT_RC_OK) return make_rc_error(env, err);

    ErlNifBinary request_bin;
    if (!enif_inspect_binary(env, argv[0], &request_bin)) {
        return make_error(env, "request must be a binary");
    }

    std::string nonce_str;
    std::string evidences_str;
    std::string scratch_dir = "/tmp";
    try {
        json request = json::parse(std::string(
            reinterpret_cast<char*>(request_bin.data), request_bin.size));
        if (!request.is_object()) {
            return make_error(env, "request must be a JSON object");
        }
        if (!request.contains("nonce") || !request["nonce"].is_string()) {
            return make_error(env, "request has no nonce");
        }
        if (!request.contains("evidences") || !request["evidences"].is_array()) {
            return make_error(env, "request has no evidences array");
        }
        nonce_str = request["nonce"].get<std::string>();
        evidences_str = request["evidences"].dump();
        if (request.contains("scratch-dir") && request["scratch-dir"].is_string()) {
            scratch_dir = request["scratch-dir"].get<std::string>();
        }
    } catch (...) {
        return make_error(env, "request is not valid JSON");
    }

    nvat_nonce_t raw_nonce = nullptr;
    err = nvat_nonce_from_hex(&raw_nonce, nonce_str.c_str());
    if (err != NVAT_RC_OK) return make_rc_error(env, err);
    nvat_ptr<nvat_nonce_t> nonce(&raw_nonce);

    /* NVAT reads existing GPU evidence from a JSON file. */
    ScratchFile evidence_file;
    if (!evidence_file.create(scratch_dir, evidences_str)) {
        return make_error(env, "cannot write evidence to the scratch directory");
    }

    nvat_attestation_ctx_t raw_ctx = nullptr;
    nvat_ptr<nvat_attestation_ctx_t> ctx;
    err = make_local_gpu_ctx(ctx, raw_ctx);
    if (err != NVAT_RC_OK) return make_rc_error(env, err);

    err = nvat_attestation_ctx_set_gpu_evidence_source_json_file(raw_ctx,
                                                                 evidence_file.path.c_str());
    if (err != NVAT_RC_OK) return make_rc_error(env, err);

    json result;
    attest_into(raw_ctx, raw_nonce, result);

    return make_ok(env, make_binary(env, result.dump()));
}

/* loaded() */
static ERL_NIF_TERM loaded_nif(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    return make_atom(env, "true");
}

/* ============================================================================
 * Registration
 * ============================================================================ */

static ErlNifFunc nif_funcs[] = {
    {"loaded", 0, loaded_nif, 0},
    {"collect_evidence", 1, collect_evidence_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"verify_evidence", 1, verify_evidence_nif, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

static int load(ErlNifEnv* env, void** priv_data, ERL_NIF_TERM load_info) {
    (void)env;
    (void)priv_data;
    (void)load_info;
    return 0;
}

static void unload(ErlNifEnv* env, void* priv_data) {
    (void)env;
    (void)priv_data;
    std::lock_guard<std::mutex> lock(sdk_mutex);
    if (sdk_initialized) {
        nvat_sdk_shutdown();
        sdk_initialized = false;
    }
}

extern "C" {
    ERL_NIF_INIT(dev_sev_gpu_nif, nif_funcs, load, NULL, NULL, unload)
}
