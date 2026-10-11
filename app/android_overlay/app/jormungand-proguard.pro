# libbox is a gomobile library: Go calls these classes by name over JNI (and the platform
# interface callbacks implemented in Kotlin), so R8 must neither rename nor drop them.
-keep class go.** { *; }
-keep class io.nekohasekai.libbox.** { *; }
-keep class __APP_ID__.** { *; }
-dontwarn go.**
-dontwarn io.nekohasekai.libbox.**

# Room (WorkManager's WorkDatabase) creates the generated *_Impl by reflection through its no-arg
# constructor; R8 full mode drops constructors that a bare `-keep class` does not name.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
