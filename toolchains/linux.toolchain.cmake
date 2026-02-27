set(CMAKE_C_COMPILER "clang")
set(CMAKE_CXX_COMPILER "clang")
set(CMAKE_C_FLAGS "-fPIC")
set(CMAKE_Swift_FLAGS "-resource-dir $ENV{SWIFT_RESOURCE_DIR} -ldispatch -lstdc++ -lm -lFoundationEssentials -l_FoundationCollections -l_FoundationCShims -lswiftSynchronization")
