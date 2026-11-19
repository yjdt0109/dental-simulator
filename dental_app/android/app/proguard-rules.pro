# MediaPipe(얼굴 특징점)는 protobuf 필드 이름을 실행 중에 찾으므로 이름을 바꾸지 않게 지킴
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite { <fields>; <methods>; }
-dontwarn com.google.mediapipe.**
-dontwarn com.google.protobuf.**
-dontwarn javax.lang.model.**
-dontwarn com.google.auto.value.**
-keep class com.google.common.flogger.** { *; }
-dontwarn com.google.common.flogger.**
