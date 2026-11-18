package com.xycz.simple_live

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 应用内更新：把下载好的 APK 交给系统安装（通道 simple_live/app_update）。
 * Dart -> 原生：canInstall、openInstallSettings、installApk(path)。
 * APK 放在缓存目录的 update 文件夹，经 [UpdateFileProvider] 给系统安装器读
 */
object AppUpdate {
    const val CHANNEL = "simple_live/app_update"

    fun attach(context: Context, messenger: BinaryMessenger) {
        val appContext = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> result.success(canInstall(appContext))
                "openInstallSettings" -> result.success(openInstallSettings(appContext))
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("no_path", "Missing path", null)
                        return@setMethodCallHandler
                    }
                    try {
                        installApk(appContext, File(path))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 安卓 8 起每个 App 要单独允许“安装未知应用”；更早的系统由安装界面自己提示 */
    private fun canInstall(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            context.packageManager.canRequestPackageInstalls()

    private fun openInstallSettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return false
        }
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:" + context.packageName),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun installApk(context: Context, file: File) {
        val uri = FileProvider.getUriForFile(context, context.packageName + ".update_provider", file)
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }
}

/** 更新专用的 FileProvider：用自己的类名，和插件声明的 FileProvider 在清单合并时不冲突 */
class UpdateFileProvider : FileProvider()
