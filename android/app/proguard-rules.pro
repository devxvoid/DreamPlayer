# BouncyCastle (bcprov) registers algorithms by reflection via
# Provider.put("MessageDigest.MD4", "org.bouncycastle.jce.provider.JDKMessageDigest$MD4")
# using string class names. R8 renaming these classes breaks the provider, so
# jcifs-ng NTLM MD4 startup throws i8.g1 cannot be cast to i8.j0 in release.
# Keep the whole provider intact (only it, not the rest of the BC crypto API).
-keep class org.bouncycastle.jce.provider.BouncyCastleProvider { <init>(); }
-keep class org.bouncycastle.jcajce.provider.** { *; }
-keep class org.bouncycastle.jce.provider.** { *; }
-keepclasseswithmembernames class org.bouncycastle.** { <init>(...); }
-dontwarn org.bouncycastle.**
