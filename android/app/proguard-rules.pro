# Kuromoji's dictionary files (connectionCosts.bin, tokenInfoDictionary.bin, etc. — see
# JapaneseReadingHandler) are loaded via Java's ObjectInputStream, which deserializes objects
# by matching field names/order against the exact class shape they were serialized with. R8's
# default obfuscation renames and reorders those fields, so without these keep rules the
# 독음 (Korean phonetic reading) tier silently fails to load in release builds — the resulting
# exception is caught in JapaneseReadingHandler and degrades to "phonetic unavailable" instead
# of crashing, which is why this had no visible error to go on.
-keep class com.atilika.kuromoji.** { *; }
-keepclassmembers class com.atilika.kuromoji.** { *; }
-dontwarn com.atilika.kuromoji.**
