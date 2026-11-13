# flutter_local_notifications 18 uses Gson to restore persisted schedules.
# R8 full mode must retain TypeToken's generic superclass, including anonymous
# subclasses. Keep this narrow; release shrinking stays enabled.
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken { *; }
-keep class com.dexterous.flutterlocalnotifications.models.** { *; }
