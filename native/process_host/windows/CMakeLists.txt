cmake_minimum_required(VERSION 3.14)
project(gapless_process_host_tests LANGUAGES CXX)

add_executable(gapless_process_host process_host.cpp)
target_compile_features(gapless_process_host PRIVATE cxx_std_17)
target_compile_options(gapless_process_host PRIVATE /W4 /WX /EHsc)
target_compile_definitions(gapless_process_host PRIVATE
  _WIN32_WINNT=0x0A00
  UNICODE
  _UNICODE
  GAPLESS_PROCESS_HOST_TESTING=1)
