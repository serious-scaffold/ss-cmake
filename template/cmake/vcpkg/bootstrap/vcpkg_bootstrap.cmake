#[[
SPDX-License-Identifier: MIT
SPDX-FileCopyrightText: Copyright 2023 Mikhail Svetkin
SPDX-FileCopyrightText: Copyright 2024 msclock
]]

# stash all local changes
function(_vcpkg_stash vcpkg_root)
  message(STATUS "vcpkg stash all local changes")

  execute_process(
    COMMAND ${GIT_EXECUTABLE} stash
    WORKING_DIRECTORY ${vcpkg_root}
    RESULT_VARIABLE result)

  if(NOT result EQUAL "0")
    message(FATAL_ERROR "${GIT_EXECUTABLE} stash failed with ${result}")
  endif()
endfunction()

# checkout to a specific baseline
function(_vcpkg_checkout vcpkg_root vcpkg_ref)
  message(STATUS "vcpkg checkout to ${vcpkg_ref}")

  if(EXISTS "${vcpkg_root}/.git/shallow")
    message(
      WARNING
        "vcpkg is shallow now and unshallow to retrieve the Git tree object hash for a specific version port......"
    )
    execute_process(
      COMMAND ${GIT_EXECUTABLE} fetch --unshallow
      WORKING_DIRECTORY ${vcpkg_root}
      RESULT_VARIABLE result)

    if(NOT result EQUAL "0")
      message(
        FATAL_ERROR "${GIT_EXECUTABLE} fetch --unshallow failed with ${result}")
    endif()
  endif()

  execute_process(
    COMMAND ${GIT_EXECUTABLE} checkout ${vcpkg_ref}
    WORKING_DIRECTORY ${vcpkg_root}
    RESULT_VARIABLE result)

  if(NOT result EQUAL "0")
    message(
      FATAL_ERROR
        "${GIT_EXECUTABLE} checkout ${vcpkg_ref} failed with ${result}")
  endif()
endfunction()

# clone
function(_vcpkg_clone vcpkg_root vcpkg_repo vcpkg_ref)
  execute_process(
    COMMAND ${GIT_EXECUTABLE} clone ${vcpkg_repo} ${vcpkg_root}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    RESULT_VARIABLE result)

  if(NOT result EQUAL "0")
    message(FATAL_ERROR "failed to clone ${vcpkg_repo} to ${vcpkg_root}")
  endif()

  file(LOCK "${vcpkg_root}" DIRECTORY)
  _vcpkg_checkout(${vcpkg_root} ${vcpkg_ref})
endfunction()

# bootstrap
function(_vcpkg_tool_bootstrap vcpkg_root)
  message(STATUS "Bootstrap vckpg tool")

  if("${__vcpkg_bootstrap_host}" STREQUAL "Windows")
    set(bootstrap_cmd "${vcpkg_root}/bootstrap-vcpkg.bat")
  else()
    set(bootstrap_cmd "${vcpkg_root}/bootstrap-vcpkg.sh")
  endif()

  execute_process(
    COMMAND ${bootstrap_cmd} -disableMetrics
    WORKING_DIRECTORY ${vcpkg_root}
    RESULT_VARIABLE result)

  if(NOT result EQUAL "0")
    if(CMAKE_HOST_UNIX)
      message(STATUS "Retry to build vcpkg from source...")
      set(bootstrap_impl "${vcpkg_root}/scripts/bootstrap.sh")
      file(READ "${bootstrap_impl}" file_contents)
      string(REPLACE [[elif [ "$ARCH" = "x86_64" ]; then]]
                     [[elif [ "$ARCH" = "" ]; then]] file_contents
                     "${file_contents}")
      message(STATUS "Replace vcpkg sources")
      string(
        REPLACE
          [[(cd "$buildDir" && cmake --build .) || exit 1]]
          [[(sed -i 's/InternalFeatureSet separate_features{{FeatureNameCore.to_string(), feature->name}};/InternalFeatureSet separate_features{{FeatureNameCore.to_string()}}; separate_features.push_back(feature->name);/' $srcDir/src/vcpkg/commands.test-features.cpp && cd "$buildDir" && cmake --build .) || exit 1]]
          file_contents
          "${file_contents}")
      file(WRITE "${bootstrap_impl}" "${file_contents}")

      execute_process(
        COMMAND ${bootstrap_cmd} -disableMetrics
        WORKING_DIRECTORY ${vcpkg_root}
        RESULT_VARIABLE result)
    endif()

    if(NOT result EQUAL "0")
      message(FATAL_ERROR "${bootstrap_cmd} failed with ${result}")
    endif()
  endif()
endfunction()

# upgrade
function(_vcpkg_upgrade vcpkg_root vcpkg_repo vcpkg_ref)
  file(LOCK "${vcpkg_root}" DIRECTORY)

  if(NOT EXISTS "${vcpkg_root}/.git")
    message(WARNING "vcpkg not found in git work tree, skipping upgrade")
    return()
  endif()

  # Check .gitconfig on linux or windows
  if(EXISTS "$ENV{HOME}/.gitconfig" OR EXISTS "$ENV{USERPROFILE}/.gitconfig")
    execute_process(
      COMMAND ${GIT_EXECUTABLE} config --get-all safe.directory
      WORKING_DIRECTORY ${vcpkg_root}
      OUTPUT_VARIABLE safe_directory
      OUTPUT_STRIP_TRAILING_WHITESPACE
      RESULT_VARIABLE result)
  endif()

  if(NOT DEFINED safe_directory
     OR (DEFINED safe_directory AND NOT safe_directory MATCHES "${vcpkg_root}"))
    message(STATUS "vcpkg root is not in the git safe directory, adding...")

    execute_process(
      COMMAND ${GIT_EXECUTABLE} config --global safe.directory ${vcpkg_root}
              --append
      WORKING_DIRECTORY ${vcpkg_root}
      RESULT_VARIABLE result)

    if(NOT result EQUAL "0")
      message(FATAL_ERROR "${GIT_EXECUTABLE} config failed with ${result}")
    endif()
  endif()

  execute_process(
    COMMAND ${GIT_EXECUTABLE} rev-parse HEAD
    WORKING_DIRECTORY ${vcpkg_root}
    OUTPUT_VARIABLE current_git_hash
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE result)

  if(NOT result EQUAL "0")
    message(
      FATAL_ERROR "${GIT_EXECUTABLE} rev-parse HEAD failed with ${result}")
  endif()

  if("${current_git_hash}" STREQUAL "${vcpkg_ref}")
    return()
  endif()

  message(STATUS "Upgrade vcpkg")
  message(STATUS "vcpkg current commit: ${current_git_hash}")
  message(STATUS "vcpkg target commit:  ${vcpkg_ref}")

  execute_process(
    COMMAND ${GIT_EXECUTABLE} remote set-url origin ${vcpkg_repo}
    WORKING_DIRECTORY ${vcpkg_root}
    RESULT_VARIABLE result)

  if(NOT result EQUAL "0")
    message(FATAL_ERROR "failed to change origin to ${vcpkg_repo}")
  endif()

  execute_process(
    COMMAND ${GIT_EXECUTABLE} fetch
    WORKING_DIRECTORY ${vcpkg_root}
    RESULT_VARIABLE result)

  if(NOT result EQUAL "0")
    message(FATAL_ERROR "${GIT_EXECUTABLE} fetch failed with ${result}")
  endif()

  _vcpkg_stash(${vcpkg_root})
  _vcpkg_checkout(${vcpkg_root} ${vcpkg_ref})
  _vcpkg_tool_bootstrap(${vcpkg_root})
endfunction()

# find root
function(_vcpkg_find_root cache_dir_name out_vcpkg_root)
  if("${__vcpkg_bootstrap_host}" STREQUAL "Windows")
    set(root "$ENV{LOCALAPPDATA}/vcpkg/projects/${cache_dir_name}/cache")
  else()
    set(root "$ENV{HOME}/.cache/vcpkg/projects/${cache_dir_name}")
  endif()

  set(${out_vcpkg_root}
      ${root}
      PARENT_SCOPE)
endfunction()

# set vcpkg_root/toolchain_file cache variables
function(_vcpkg_set_cache_variables vcpkg_root)
  set(_VCPKG_ROOT
      "${vcpkg_root}"
      CACHE INTERNAL "vcpkg root")

  set(_VCPKG_TOOLCHAIN_FILE
      "${vcpkg_root}/scripts/buildsystems/vcpkg.cmake"
      CACHE INTERNAL "vcpkg toolchain file")
endfunction()

# bootstrap
function(_vcpkg_bootstrap)
  cmake_parse_arguments(PARSE_ARGV 0 "arg" "" "CACHE_DIR_NAME;REPO;REF" "")

  if(DEFINED arg_UNPARSED_ARGUMENTS)
    message(
      FATAL_ERROR "internal error: ${CMAKE_CURRENT_FUNCTION} passed extra args:"
                  "${arg_UNPARSED_ARGUMENTS}")
  endif()

  if(NOT DEFINED arg_REPO)
    set(arg_REPO https://github.com/microsoft/vcpkg.git)
  endif()

  find_package(Git QUIET REQUIRED)

  if(DEFINED CACHE{_VCPKG_ROOT})
    set(vcpkg_root $CACHE{_VCPKG_ROOT})
  else()
    _vcpkg_find_root("${arg_CACHE_DIR_NAME}" vcpkg_root)
  endif()

  if(NOT EXISTS ${vcpkg_root})
    message(STATUS "Setup vcpkg")
    _vcpkg_clone(${vcpkg_root} ${arg_REPO} ${arg_REF})
    _vcpkg_tool_bootstrap(${vcpkg_root})
  else()
    message(STATUS "Found vcpkg in: ${vcpkg_root}")
    _vcpkg_upgrade(${vcpkg_root} ${arg_REPO} ${arg_REF})
  endif()

  _vcpkg_set_cache_variables("${vcpkg_root}")

  # Make sure downloads folder is 755 on linux
  if(CMAKE_HOST_UNIX)
    execute_process(
      COMMAND chmod 755 ${vcpkg_root}/downloads
      WORKING_DIRECTORY ${vcpkg_root}
      RESULT_VARIABLE result)

    if(NOT result EQUAL "0")
      message(STATUS "failed to chmod 755 ${vcpkg_root}/downloads")
    endif()
  endif()
endfunction()
