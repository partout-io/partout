# Native entry points use Java_io_partout_PartoutWrapper_* symbol names.
-keepclasseswithmembers,includedescriptorclasses class io.partout.PartoutWrapper {
    native <methods>;
}

# The runtime resolves controller callbacks by name and signature through JNI.
-keep class io.partout.NativeTunnelControllerJNI { *; }
-keepclassmembers class * implements io.partout.NativeTunnelControllerJNI { *; }

-keepclasseswithmembers,includedescriptorclasses class io.partout.vpn.PartoutTunnelController {
    native <methods>;
}
