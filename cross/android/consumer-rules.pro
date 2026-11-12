# Native entry points use Java_io_partout_PartoutWrapper_* symbol names.
-keepclasseswithmembers,includedescriptorclasses class io.partout.PartoutWrapper {
    native <methods>;
}

# The runtime resolves controller callbacks by name and signature through JNI.
-keep interface io.partout.NativeTunnelControllerJNI {
    public long setDelegate(long);
    public int setTunnel(java.lang.String);
    public void configureSockets(int[]);
    public void onSnapshot(java.lang.String);
    public void setEnvironmentValue(java.lang.String, java.lang.String);
    public void clearTunnel(boolean);
    public void cancelTunnel(java.lang.String);
}
-keepclassmembers class * implements io.partout.NativeTunnelControllerJNI {
    public long setDelegate(long);
    public int setTunnel(java.lang.String);
    public void configureSockets(int[]);
    public void onSnapshot(java.lang.String);
    public void setEnvironmentValue(java.lang.String, java.lang.String);
    public void clearTunnel(boolean);
    public void cancelTunnel(java.lang.String);
}

-keepclasseswithmembers,includedescriptorclasses class io.partout.vpn.PartoutTunnelController {
    native <methods>;
}
