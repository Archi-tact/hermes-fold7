package ai.hermesfold7.hands;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.WindowInsets;
import android.widget.FrameLayout;
import android.webkit.CookieManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

/**
 * Hermes 대화창 — Hermes Fold 화면(http://127.0.0.1:9130)을 '진짜 앱'으로 띄움.
 *  · singleTask: 홈 아이콘·알림 어디서 열어도 항상 '하던 그 창'으로 돌아옴 (새 탭/새 창 안 생김)
 *  · 화면 분할·팝업 화면 지원: Hands 가 앱을 조작할 때 그 앱을 대화창 옆 칸에 열어 진행 상황을 계속 볼 수 있음
 *  · 접기/펴기·창 크기 변경에도 다시 로드하지 않음 (configChanges)
 */
public class ChatActivity extends Activity {
    static final String TAG = "HermesChat";
    static final String HOME = "http://127.0.0.1:9130/";
    private static volatile ChatActivity visible;   // 지금 화면에 보이는 대화창 (화면 분할 실행에 사용)
    private WebView web;

    static ChatActivity visible() { return visible; }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#1b1a18"));
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);            // 마지막 대화 기억(localStorage)
        s.setMediaPlaybackRequiresUserGesture(true);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        CookieManager.getInstance().setAcceptCookie(true);   // 로그인(30일) 유지
        web.setWebChromeClient(new WebChromeClient());
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                Uri u = r.getUrl();
                if ("127.0.0.1".equals(u.getHost()) && "http".equals(u.getScheme())) return false;   // 대화창 안
                try { startActivity(new Intent(Intent.ACTION_VIEW, u)); } catch (Exception e) { Log.w(TAG, "open: " + e); }
                return true;                                                                          // 바깥 링크는 브라우저로
            }
            @Override public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError e) {
                if (r.isForMainFrame()) showOffline();
            }
        });
        // Android 15(targetSdk 35)는 앱을 화면 끝까지 그림 → 펼친 폴드의 아래 작업 표시줄·내비 바·키보드에 입력창이 가려짐
        //   → 시스템 바 · 화면 구멍 · 키보드 높이만큼 여백을 줘서 항상 보이게
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.parseColor("#1b1a18"));
        root.addView(web, new FrameLayout.LayoutParams(-1, -1));
        root.setOnApplyWindowInsetsListener((v, in) -> {
            int pl, pt, pr, pb;
            if (Build.VERSION.SDK_INT >= 30) {
                Insets bars = in.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                pl = bars.left; pt = bars.top; pr = bars.right; pb = bars.bottom;
            } else {
                pl = in.getSystemWindowInsetLeft(); pt = in.getSystemWindowInsetTop(); pr = in.getSystemWindowInsetRight(); pb = in.getSystemWindowInsetBottom();
            }
            v.setPadding(pl, pt, pr, pb);
            return in;
        });
        setContentView(root);
        if (b != null) web.restoreState(b);
        if (web.getUrl() == null) web.loadUrl(HOME);
    }

    /** 서버가 꺼져 있을 때: 빈 화면 대신 켜는 방법 + 다시 시도 버튼. */
    private void showOffline() {
        String html = "<html><head><meta name=viewport content='width=device-width'><style>"
                + "body{background:#1b1a18;color:#eee;font:16px sans-serif;padding:28px;line-height:1.6}"
                + "code{background:#333;padding:2px 6px;border-radius:6px}button{font-size:17px;padding:12px 22px;border-radius:12px;border:0;background:#6d5efc;color:#fff}"
                + "</style></head><body><h2>Hermes 서버가 꺼져 있어요</h2>"
                + "<p>Termux 에서 아래를 실행한 뒤 '다시 시도'를 누르세요.</p>"
                + "<p><code>bash ~/hermes-fold7/scripts/80-hermes-fold.sh start</code></p>"
                + "<button onclick=\"location.href='" + HOME + "'\">다시 시도</button></body></html>";
        web.loadDataWithBaseURL("about:blank", html, "text/html", "utf-8", null);
    }

    @Override protected void onNewIntent(Intent i) {   // 이미 열린 창으로 돌아옴 → 페이지는 그대로 (화면이 알아서 다시 연결)
        super.onNewIntent(i);
        setIntent(i);
        String u = web.getUrl();
        if (u == null || !u.startsWith(HOME)) web.loadUrl(HOME);
    }

    @Override protected void onResume() { super.onResume(); visible = this; web.onResume(); }
    @Override protected void onPause() { super.onPause(); CookieManager.getInstance().flush(); web.onPause(); }
    // 화면 분할 중 다른 칸을 만지면 onPause 만 옴(계속 보임) → '보임'은 onStop 에서만 해제
    @Override protected void onStop() { super.onStop(); if (visible == this) visible = null; }
    @Override protected void onDestroy() { if (visible == this) visible = null; web.destroy(); super.onDestroy(); }
    @Override protected void onSaveInstanceState(Bundle o) { super.onSaveInstanceState(o); web.saveState(o); }

    @Override public void onBackPressed() {
        if (web.canGoBack()) web.goBack(); else moveTaskToBack(true);   // 뒤로 = 창 닫지 않고 내려두기 (대화 유지)
    }

    /** Hands 가 앱을 열 때: 대화창이 보이면 그 앱을 '옆 칸(화면 분할)'에 열어 대화창을 계속 보이게 함. */
    boolean launchAdjacent(Intent it) {
        if (isFinishing() || isDestroyed()) return false;
        it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_LAUNCH_ADJACENT);
        try { startActivity(it); return true; } catch (Exception e) { Log.w(TAG, "adjacent: " + e); return false; }
    }
}
