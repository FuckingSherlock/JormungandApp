# libbox is a gomobile library: Go calls these classes by name over JNI (and the platform
# interface callbacks implemented in Kotlin), so R8 must neither rename nor drop them.
-keep class go.** { *; }
-keep class io.nekohasekai.libbox.** { *; }
-keep class __APP_ID__.** { *; }
-dontwarn go.**
-dontwarn io.nekohasekai.libbox.**
