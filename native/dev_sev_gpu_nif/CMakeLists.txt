cmake_minimum_required(VERSION 3.13)
project(dev_sev_gpu_nif VERSION 0.2.0 LANGUAGES CXX)

# Verbose NVAT SDK logging (default: errors only).
option(NVAT_DEBUG_LOG "Enable verbose debug logging from the NVAT SDK" OFF)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Erlang: erl_nif.h for the NIF and erlc for the wrapper module.
find_program(ERL_EXECUTABLE erl)
find_program(ERLC_EXECUTABLE erlc)
if(NOT ERLC_EXECUTABLE)
    message(FATAL_ERROR "Could not find erlc. Install Erlang/OTP.")
endif()

set(ERTS_INCLUDE_HINT "")
if(ERL_EXECUTABLE)
    execute_process(
        COMMAND ${ERL_EXECUTABLE} -noshell -eval
            "io:format(\"~s/erts-~s/include\", [code:root_dir(), erlang:system_info(version)]), halt()."
        OUTPUT_VARIABLE ERTS_INCLUDE_HINT
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
    )
endif()

find_path(ERL_NIF_INCLUDE_DIR erl_nif.h
    HINTS ${ERTS_INCLUDE_HINT}
          /usr/local/lib/erlang/usr/include
          /usr/lib/erlang/usr/include
)
if(NOT ERL_NIF_INCLUDE_DIR)
    message(FATAL_ERROR "Could not find erl_nif.h. Install the Erlang development headers.")
endif()

# NVAT SDK source and build directories (passed by the Makefile).
set(NVAT_SDK_DIR "" CACHE PATH "Path to the NVAT SDK source")
set(NVAT_BUILD_DIR "" CACHE PATH "Path to the NVAT SDK build")
if(NOT NVAT_SDK_DIR OR NOT NVAT_BUILD_DIR)
    message(FATAL_ERROR "NVAT_SDK_DIR and NVAT_BUILD_DIR must be specified")
endif()

# nlohmann/json is fetched by the NVAT SDK build.
find_path(NLOHMANN_JSON_INCLUDE_DIR nlohmann/json.hpp
    HINTS ${NVAT_BUILD_DIR}/_deps/json-src/include
          ${NVAT_BUILD_DIR}/_deps/json-src/single_include
)
if(NOT NLOHMANN_JSON_INCLUDE_DIR)
    message(FATAL_ERROR "Could not find nlohmann/json.hpp. Build the NVAT SDK first.")
endif()

add_library(dev_sev_gpu_nif SHARED
    dev_sev_gpu_nif.cpp
)

target_include_directories(dev_sev_gpu_nif PRIVATE
    ${ERL_NIF_INCLUDE_DIR}
    ${NVAT_BUILD_DIR}/include
    ${NLOHMANN_JSON_INCLUDE_DIR}
)

target_link_directories(dev_sev_gpu_nif PRIVATE
    ${NVAT_BUILD_DIR}
)

target_link_libraries(dev_sev_gpu_nif PRIVATE
    nvat
)

if(NVAT_DEBUG_LOG)
    target_compile_definitions(dev_sev_gpu_nif PRIVATE NVAT_DEBUG_LOG)
endif()

# Erlang loads NIF libraries as `<name>.so'. The NVAT shared library ships in
# a `lib' directory next to the NIF: `$ORIGIN/lib' is the Device Forge
# implementation archive and `priv/dev_sev_gpu' layout, and `$ORIGIN/../lib'
# covers installations that keep the NIF one level below the libraries.
set_target_properties(dev_sev_gpu_nif PROPERTIES
    PREFIX ""
    SUFFIX ".so"
    INSTALL_RPATH "$ORIGIN/lib;$ORIGIN/../lib"
    BUILD_WITH_INSTALL_RPATH TRUE
)

# The wrapper module that owns the NIF. Ship dev_sev_gpu_nif.beam next to
# dev_sev_gpu_nif.so.
set(DEV_SEV_GPU_NIF_BEAM ${CMAKE_CURRENT_BINARY_DIR}/dev_sev_gpu_nif.beam)
add_custom_command(
    OUTPUT ${DEV_SEV_GPU_NIF_BEAM}
    COMMAND ${ERLC_EXECUTABLE} -o ${CMAKE_CURRENT_BINARY_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/dev_sev_gpu_nif.erl
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/dev_sev_gpu_nif.erl
    COMMENT "Compiling the dev_sev_gpu_nif wrapper module"
    VERBATIM
)
add_custom_target(dev_sev_gpu_nif_beam ALL DEPENDS ${DEV_SEV_GPU_NIF_BEAM})
add_dependencies(dev_sev_gpu_nif dev_sev_gpu_nif_beam)
