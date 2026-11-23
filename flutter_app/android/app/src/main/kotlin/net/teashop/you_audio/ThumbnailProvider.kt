package net.teashop.you_audio

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

/**
 * Read-only access to downloaded thumbnails for Android Auto.
 *
 * The library lives in app-private storage (`app_flutter/library/thumbs`), and
 * Android Auto runs in another process, so it can't open the `file://` art
 * URIs the app uses on the phone. Browse items therefore use
 * `content://net.teashop.you_audio.thumbs/<videoId>.jpg`, served from here.
 *
 * Only `<11-char video id>.jpg` names inside the thumbs dir resolve; anything
 * else (path traversal included) is a FileNotFoundException.
 */
class ThumbnailProvider : ContentProvider() {
    private val namePattern = Regex("^[A-Za-z0-9_-]{11}\\.jpg$")

    override fun onCreate(): Boolean = true

    private fun thumbsDir(context: Context): File =
        // path_provider's getApplicationDocumentsDirectory() == getDir("flutter").
        File(context.getDir("flutter", Context.MODE_PRIVATE), "library/thumbs")

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("read-only")
        val name = uri.lastPathSegment ?: throw FileNotFoundException("no name")
        if (!namePattern.matches(name)) throw FileNotFoundException(name)
        val ctx = context ?: throw FileNotFoundException("no context")
        val file = File(thumbsDir(ctx), name)
        if (!file.isFile) throw FileNotFoundException(name)
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String = "image/jpeg"

    override fun query(
        uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?,
    ): Int = 0
}
