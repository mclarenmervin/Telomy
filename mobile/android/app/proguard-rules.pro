# Vendor BLE libraries use reflection; preserve interfaces and bean names.
-keep,allowoptimization class com.bonlala.** { *; }
-keep,allowoptimization class com.inuker.** { *; }
-keep,allowoptimization interface com.bonlala.** { *; }
-keep,allowoptimization interface com.inuker.** { *; }
-keep,allowoptimization class no.nordicsemi.** { *; }
-dontwarn no.nordicsemi.**
# Vendor parsers log raw health packets. Strip logging in test AND release APKs.
-assumenosideeffects class android.util.Log {
    public static *** v(...);
    public static *** d(...);
    public static *** i(...);
    public static *** w(...);
    public static *** e(...);
    public static *** wtf(...);
    public static *** println(...);
}
-assumenosideeffects class java.io.PrintStream {
    public void print(...);
    public void println(...);
}
# The vendor's optional BleApplication is unused: Telomy uses Flutter's
# application lifecycle and initializes BonlalaOperateManager directly.
-dontwarn org.litepal.LitePal
-dontwarn org.litepal.LitePalApplication
