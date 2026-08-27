package com.dreamplayer.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.browser.customtabs.CustomTabsIntent
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.flutter.plugin.common.MethodChannel
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Google Drive browser + streaming auth (channel `dreamplayer/gdrive`).
 *
 * Mirrors the WebDAV/Jellyfin pattern: accounts persist in app-private
 * SharedPreferences (email/displayName) and secrets in
 * EncryptedSharedPreferences (refresh/access token + expiry). Browsing is
 * `GET https://www.googleapis.com/drive/v3/files?q='...' in parents` with a
 * Bearer header; playback streams `.../drive/v3/files/{id}?alt=media` with the
 * same header (ExoPlayer's OkHttp DataSource honors per-item headers).
 *
 * OAuth: Custom Tabs -> https://accounts.google.com/o/oauth2/v2/auth
 * (scope drive.readonly, offline access) -> redirect `com.dreamplayer.app:/oauth2redirect`
 * -> code exchange at https://oauth2.googleapis.com/token.
 * The client id/secret are supplied by Dart from `cloud_keys.dart`
 * (build-time `--dart-define` from `.env`) so they never live in the APK.
 */
class GDriveClient(private val context: Context) {

    companion object {
        const val CHANNEL = "dreamplayer/gdrive"
        private const val PREFS = "dreamplayer.gdriveAccounts"
        private const val SECRETS_PREFS = "dreamplayer.gdriveSecrets"
        private const val ACCOUNTS_KEY = "accounts"

        private const val REDIRECT_URI = "com.dreamplayer.app:/oauth2redirect"
        private const val AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
        private const val TOKEN_URL = "https://oauth2.googleapis.com/token"
        private const val SCOPE = "https://www.googleapis.com/auth/drive.readonly"
        private const val USERINFO_URL = "https://www.googleapis.com/oauth2/v2/userinfo"

        private val VIDEO_EXTENSIONS = setOf(
            "mkv", "mp4", "mov", "avi", "webm", "m4v", "ts", "m2ts", "mts",
            "wmv", "flv", "mpg", "mpeg", "3gp", "3g2", "vob", "divx", "xvid", "m2v",
        )

        @Volatile
        var pendingResult: MethodChannel.Result? = null
        @Volatile
        var pendingState: String? = null
        @Volatile
        var pendingClientId: String? = null
        @Volatile
        var pendingClientSecret: String? = null
        @Volatile
        var pendingVerifier: String? = null
        var instance: GDriveClient? = null

        fun handleOAuthRedirect(intent: Intent?): Boolean {
            val data: Uri = intent?.data ?: return false
            if (data.scheme != "com.dreamplayer.app") return false
            // Accept both com.dreamplayer.app:/oauth2redirect and host variant.
            val path = data.path ?: ""
            val host = data.host ?: ""
            if (!path.contains("oauth2redirect") && host != "oauth2redirect") return false
            val code = data.getQueryParameter("code")
            val state = data.getQueryParameter("state")
            val error = data.getQueryParameter("error")
            val result = pendingResult ?: return true
            val clientId = pendingClientId
            val clientSecret = pendingClientSecret
            if (error != null) {
                pendingResult = null
                pendingState = null
                Handler(Looper.getMainLooper()).post {
                    result.error("gdrive_auth", error, null)
                }
                return true
            }
            if (state != null && state != pendingState) {
                pendingResult = null
                pendingState = null
                Handler(Looper.getMainLooper()).post {
                    result.error("gdrive_auth", "State mismatch", null)
                }
                return true
            }
            if (code == null) {
                pendingResult = null
                pendingState = null
                Handler(Looper.getMainLooper()).post {
                    result.error("gdrive_auth", "Missing auth code", null)
                }
                return true
            }
            // Exchange code off main thread.
            Thread {
                try {
                    val inst = instance
                    if (inst == null || clientId == null) {
                        throw RuntimeException("GDrive not initialized")
                    }
                    val account = inst.exchangeCode(
                        code = code,
                        clientId = clientId,
                        clientSecret = clientSecret ?: "",
                    )
                    Handler(Looper.getMainLooper()).post {
                        pendingResult = null
                        pendingState = null
                        pendingClientId = null
                        pendingClientSecret = null
                        result.success(account)
                    }
                } catch (e: Exception) {
                    Handler(Looper.getMainLooper()).post {
                        pendingResult = null
                        pendingState = null
                        result.error("gdrive_auth", e.message ?: "Auth failed", null)
                    }
                }
            }.start()
            return true
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private fun accountPrefs() =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private val secretsPrefs by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            SECRETS_PREFS,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun configure(channel: MethodChannel) {
        instance = this
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "listAccounts" -> result.success(listAccounts())
                "signIn" -> {
                    if (pendingResult != null) {
                        result.error("gdrive_auth", "Sign-in already in progress", null)
                        return@setMethodCallHandler
                    }
                    val clientId = call.argument<String>("clientId") ?: ""
                    val clientSecret = call.argument<String>("clientSecret") ?: ""
                    if (clientId.isEmpty()) {
                        result.error("gdrive_auth", "Missing GDRIVE_CLIENT_ID (set in .env)", null)
                        return@setMethodCallHandler
                    }
                    val activity = context as? Activity
                    if (activity == null) {
                        result.error("gdrive_auth", "No activity", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingState = UUID.randomUUID().toString()
                    pendingClientId = clientId
                    pendingClientSecret = clientSecret
                    launchAuth(activity, clientId)
                }
                "signOut" -> {
                    val id = call.argument<String>("id") ?: call.argument<String>("accountId") ?: ""
                    if (id.isNotEmpty()) signOut(id)
                    result.success(null)
                }
                "listDirectory" -> {
                    val accountId = call.argument<String>("accountId") ?: ""
                    val folderId = call.argument<String>("folderId") ?: "root"
                    runAsync(result) {
                        listDirectory(accountId, folderId)
                    }
                }
                "authorizationHeader" -> {
                    val accountId = call.argument<String>("accountId")
                        ?: call.argument<String>("id") ?: ""
                    runAsync(result) {
                        val token = getFreshAccessToken(accountId)
                        "Bearer $token"
                    }
                }
                "getFreshAccessToken" -> {
                    val accountId = call.argument<String>("accountId")
                        ?: call.argument<String>("id") ?: ""
                    runAsync(result) {
                        getFreshAccessToken(accountId)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun launchAuth(activity: Activity, clientId: String) {
        val state = pendingState ?: UUID.randomUUID().toString()
        val authUri = Uri.parse(AUTH_URL).buildUpon()
            .appendQueryParameter("client_id", clientId)
            .appendQueryParameter("redirect_uri", REDIRECT_URI)
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("scope", SCOPE)
            .appendQueryParameter("access_type", "offline")
            .appendQueryParameter("prompt", "consent")
            .appendQueryParameter("state", state)
            .build()
        try {
            val customTabs = CustomTabsIntent.Builder().build()
            customTabs.launchUrl(activity, authUri)
        } catch (_: Exception) {
            // Fallback to plain VIEW intent.
            val intent = Intent(Intent.ACTION_VIEW, authUri)
            activity.startActivity(intent)
        }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        Thread {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: Exception) {
                mainHandler.post { result.error("gdrive", e.message ?: "Failed", null) }
            }
        }.start()
    }

    // MARK: - Accounts persistence

    private fun listAccounts(): List<Map<String, Any?>> {
        val raw = accountPrefs().getString(ACCOUNTS_KEY, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                mapOf(
                    "id" to o.optString("id"),
                    "email" to o.optString("email"),
                    "displayName" to o.optString("displayName"),
                    "hasRefreshToken" to (secretsPrefs.getString("refreshToken.${o.optString("id")}", null)?.isNotEmpty() == true),
                )
            }
        } catch (_: Exception) { emptyList() }
    }

    private fun saveAccount(id: String, email: String, displayName: String) {
        val existing = try {
            val raw = accountPrefs().getString(ACCOUNTS_KEY, null)
            if (raw == null) mutableListOf<JSONObject>()
            else {
                val arr = JSONArray(raw)
                (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }.toMutableList()
            }
        } catch (_: Exception) { mutableListOf<JSONObject>() }
        existing.removeAll { it.optString("id") == id }
        existing.add(JSONObject().apply {
            put("id", id)
            put("email", email)
            put("displayName", displayName)
        })
        val out = JSONArray()
        existing.forEach { out.put(it) }
        accountPrefs().edit().putString(ACCOUNTS_KEY, out.toString()).apply()
    }

    private fun removeAccount(id: String) {
        try {
            val raw = accountPrefs().getString(ACCOUNTS_KEY, null) ?: return
            val arr = JSONArray(raw)
            val next = JSONArray()
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (o.optString("id") != id) next.put(o)
            }
            accountPrefs().edit().putString(ACCOUNTS_KEY, next.toString()).apply()
        } catch (_: Exception) {}
        secretsPrefs.edit()
            .remove("refreshToken.$id")
            .remove("accessToken.$id")
            .remove("expiresAt.$id")
            .remove("email.$id")
            .remove("displayName.$id")
            .apply()
    }

    private fun signOut(id: String) = removeAccount(id)

    // MARK: - Token handling

    @Synchronized
    fun getFreshAccessToken(accountId: String): String {
        val access = secretsPrefs.getString("accessToken.$accountId", null)
        val expiresAt = secretsPrefs.getString("expiresAt.$accountId", null)?.toLongOrNull() ?: 0L
        val now = System.currentTimeMillis()
        // 60s leeway.
        if (access != null && now < expiresAt - 60_000) return access
        val refresh = secretsPrefs.getString("refreshToken.$accountId", null)
            ?: throw RuntimeException("No refresh token — sign in again")
        val clientId = pendingClientId ?: ""
        // Try to retrieve the client id from stored prefs if pending is gone.
        // Fallback: read from the token refresh without clientSecret if needed,
        // but Web clients require secret. We stored it? For refresh we need it.
        // Store clientId/secret per account at sign-in time.
        val storedClientId = secretsPrefs.getString("clientId.$accountId", null) ?: clientId
        val storedSecret = secretsPrefs.getString("clientSecret.$accountId", null) ?: pendingClientSecret ?: ""
        if (storedClientId.isEmpty()) throw RuntimeException("Missing client ID — sign in again")
        val reqBody = FormBody.Builder()
            .add("client_id", storedClientId)
            .apply { if (storedSecret.isNotEmpty()) add("client_secret", storedSecret) }
            .add("refresh_token", refresh)
            .add("grant_type", "refresh_token")
            .build()
        val req = Request.Builder().url(TOKEN_URL).post(reqBody).build()
        client.newCall(req).execute().use { resp ->
            val body = resp.body?.string() ?: throw RuntimeException("Empty token refresh response")
            if (!resp.isSuccessful) throw RuntimeException("Token refresh failed: HTTP ${resp.code} $body")
            val json = JSONObject(body)
            val newAccess = json.optString("access_token")
            if (newAccess.isEmpty()) throw RuntimeException("No access_token in refresh")
            val expiresIn = json.optLong("expires_in", 3600)
            val newExpiresAt = System.currentTimeMillis() + expiresIn * 1000
            secretsPrefs.edit()
                .putString("accessToken.$accountId", newAccess)
                .putString("expiresAt.$accountId", newExpiresAt.toString())
                .apply()
            return newAccess
        }
    }

    private fun exchangeCode(code: String, clientId: String, clientSecret: String): Map<String, Any?> {
        val body = FormBody.Builder()
            .add("code", code)
            .add("client_id", clientId)
            .apply { if (clientSecret.isNotEmpty()) add("client_secret", clientSecret) }
            .add("redirect_uri", REDIRECT_URI)
            .add("grant_type", "authorization_code")
            .build()
        val req = Request.Builder().url(TOKEN_URL).post(body).build()
        val (accessToken, refreshToken, expiresIn) = client.newCall(req).execute().use { resp ->
            val text = resp.body?.string() ?: throw RuntimeException("Empty token response")
            if (!resp.isSuccessful) throw RuntimeException("Token exchange failed: HTTP ${resp.code} $text")
            val json = JSONObject(text)
            Triple(
                json.optString("access_token"),
                json.optString("refresh_token"),
                json.optLong("expires_in", 3600),
            )
        }
        if (accessToken.isEmpty()) throw RuntimeException("No access_token")
        // Fetch user info.
        val userReq = Request.Builder()
            .url(USERINFO_URL)
            .header("Authorization", "Bearer $accessToken")
            .build()
        val (email, name) = client.newCall(userReq).execute().use { resp ->
            if (!resp.isSuccessful) {
                // Fallback: generate id from token prefix.
                Pair("drive@google", "Google Drive")
            } else {
                val text = resp.body?.string() ?: ""
                try {
                    val j = JSONObject(text)
                    Pair(j.optString("email", "drive@google"), j.optString("name", "Google Drive"))
                } catch (_: Exception) {
                    Pair("drive@google", "Google Drive")
                }
            }
        }
        val accountId = email.ifEmpty { "gdrive_${UUID.randomUUID()}" }
        val normalizedId = accountId.lowercase()
        val expiresAt = System.currentTimeMillis() + expiresIn * 1000
        secretsPrefs.edit()
            .putString("accessToken.$normalizedId", accessToken)
            .putString("expiresAt.$normalizedId", expiresAt.toString())
            .putString("clientId.$normalizedId", clientId)
            .putString("clientSecret.$normalizedId", clientSecret)
            .apply()
        if (refreshToken.isNotEmpty()) {
            secretsPrefs.edit().putString("refreshToken.$normalizedId", refreshToken).apply()
        }
        secretsPrefs.edit()
            .putString("email.$normalizedId", email)
            .putString("displayName.$normalizedId", name)
            .apply()
        saveAccount(normalizedId, email, name)
        return mapOf(
            "id" to normalizedId,
            "email" to email,
            "displayName" to name,
            "hasRefreshToken" to (refreshToken.isNotEmpty() || secretsPrefs.getString("refreshToken.$normalizedId", null)?.isNotEmpty() == true),
        )
    }

    // MARK: - Drive listing

    private fun listDirectory(accountId: String, folderId: String): List<Map<String, Any?>> {
        val token = getFreshAccessToken(accountId)
        // Escape single quotes in folderId for Drive query.
        val safeFolder = folderId.replace("'", "\\'")
        val q = "'$safeFolder' in parents and trashed=false"
        val url = Uri.parse("https://www.googleapis.com/drive/v3/files").buildUpon()
            .appendQueryParameter("q", q)
            .appendQueryParameter("fields", "nextPageToken,files(id,name,mimeType,size,modifiedTime)")
            .appendQueryParameter("pageSize", "1000")
            .appendQueryParameter("orderBy", "folder,name")
            .build().toString()
        val req = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $token")
            .build()
        val files = mutableListOf<Map<String, Any?>>()
        client.newCall(req).execute().use { resp ->
            val body = resp.body?.string() ?: throw RuntimeException("Empty list response")
            if (!resp.isSuccessful) throw RuntimeException("Drive list failed: HTTP ${resp.code} $body")
            val json = JSONObject(body)
            val arr = json.optJSONArray("files") ?: JSONArray()
            for (i in 0 until arr.length()) {
                val f = arr.optJSONObject(i) ?: continue
                val id = f.optString("id")
                val name = f.optString("name")
                if (id.isEmpty() || name.isEmpty()) continue
                val mime = f.optString("mimeType")
                val isDir = mime == "application/vnd.google-apps.folder"
                val size = f.optString("size").toLongOrNull() ?: 0L
                if (!isDir) {
                    val ext = name.substringAfterLast('.', "").lowercase()
                    if (ext.isNotEmpty() && ext !in VIDEO_EXTENSIONS) continue
                    // If extension empty, keep (Drive may have no ext but mime video/*)
                    if (ext.isEmpty() && !mime.startsWith("video/") && mime != "application/octet-stream") {
                        // Still show if no ext but unknown mime — skip unless folder.
                        // Keep videos without extension only when mime is generic.
                        // Safer to skip non-video mime.
                        if (mime.isNotEmpty() && !mime.startsWith("video/")) continue
                    }
                }
                files.add(mapOf(
                    "id" to id,
                    "name" to name,
                    "mimeType" to mime,
                    "isDirectory" to isDir,
                    "size" to size,
                ))
            }
        }
        return files.sortedWith(
            compareByDescending<Map<String, Any?>> { it["isDirectory"] == true }
                .thenBy { (it["name"] as? String ?: "").lowercase() }
        )
    }
}
