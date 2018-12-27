package org.midori_browser.midori

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.android.synthetic.main.activity_browser.*

class WebViewClient(val activity: BrowserActivity) : WebViewClient() {

    override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean {
        if (url != null && url.startsWith("http")) {
            activity.urlBar.setText(url)
            return false
        }

        activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        return true
    }

    override fun onPageFinished(view: WebView?, url: String?) {
        val editor = activity.getSharedPreferences("config", Context.MODE_PRIVATE).edit()
        editor.putString("openTabs", url)
        editor.apply()
        super.onPageFinished(view, url)
    }
}
