package ai.hermesfold7.hands;

import android.accessibilityservice.AccessibilityService;
import android.accessibilityservice.GestureDescription;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ResolveInfo;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;

/**
 * Hermes Hands — 에이전트가 승인된 "자동화 세션" 동안에만 화면을 읽고 조작하는 접근성 서비스.
 *
 * 통신: 127.0.0.1:47800, 요청/응답 모두 한 줄 JSON. 모든 요청에 토큰 필요({"token":..,"cmd":..}).
 * 세션: start(apps, minutes, title) 이후에만 dump/click/type/scroll/launch/tap 허용.
 *       세션 중 화면 전체 보호막(사용자 터치 차단) + 가운데 일시정지 버튼.
 *       에이전트 조작은 접근성 노드 동작이라 보호막에 막히지 않음(좌표 탭만 순간 통과).
 * 안전: 앱 허용목록, 금지 앱(은행·결제), 비밀번호 칸 제외, 시간 제한, 무응답 감시, 볼륨↓ 3회 비상정지.
 */
public class HandsService extends AccessibilityService {
    static final String TAG = "HermesHands";
    static final int PORT = 47800;
    static final String PREFS = "hands";
    static final long IDLE_TIMEOUT_MS = 120_000;      // 에이전트가 2분간 아무 요청 없으면 세션 종료
    static final int MAX_NODES = 400;

    /** 이름에 이 단어가 들어간 패키지는 절대 조작하지 않음 (은행·결제·인증). */
    static final String[] DENY_SUBSTRINGS = {
            "bank", "pay", "wallet", "card", "spay", "samsungpass", "kbstar", "toss",
            "shinhan", "wooribank", "hanabank", "nhbank", "kakaobank", "upbit", "bithumb",
            "authenticator", "otp", "passkey", "keystore", "lastpass", "1password", "bitwarden"
    };

    private static volatile HandsService instance;

    private Handler main;
    private WindowManager wm;
    private ServerSocket server;
    private final Object actionLock = new Object();

    // 세션 상태
    private volatile boolean active = false, paused = false;
    private volatile long deadline = 0, lastRequest = 0;
    private volatile String title = "", step = "";
    private final Set<String> allowed = new HashSet<>();
    private volatile int stepMs = 700, highlightMs = 500;
    private final List<AccessibilityNodeInfo> lastDump = new ArrayList<>();

    // 보호막 뷰
    private FrameLayout overlay;
    private WindowManager.LayoutParams overlayLp;
    private TextView banner;
    private Button pauseBtn, resumeBtn, stopBtn;
    private View highlight;

    // 볼륨↓ 3회 비상정지
    private long volWindowStart = 0;
    private int volCount = 0;

    static HandsService get() { return instance; }

    // ───────────────────────── 생명주기 ─────────────────────────
    @Override
    protected void onServiceConnected() {
        instance = this;
        main = new Handler(Looper.getMainLooper());
        wm = (WindowManager) getSystemService(Context.WINDOW_SERVICE);
        token(this); // 없으면 생성
        startServer();
        main.postDelayed(watchdog, 1000);
        Log.i(TAG, "connected; listening on 127.0.0.1:" + PORT);
    }

    @Override
    public boolean onUnbind(Intent intent) { shutdown(); return super.onUnbind(intent); }

    @Override
    public void onDestroy() { shutdown(); super.onDestroy(); }

    private void shutdown() {
        instance = null;
        serving = false;
        try { if (server != null) server.close(); } catch (Exception ignored) { }
        if (main != null) main.post(this::removeOverlay);
        active = false;
    }

    @Override public void onAccessibilityEvent(AccessibilityEvent event) { }
    @Override public void onInterrupt() { }

    @Override
    protected boolean onKeyEvent(KeyEvent e) {
        if (active && e.getKeyCode() == KeyEvent.KEYCODE_VOLUME_DOWN && e.getAction() == KeyEvent.ACTION_DOWN) {
            long now = System.currentTimeMillis();
            if (now - volWindowStart > 2500) { volWindowStart = now; volCount = 0; }
            if (++volCount >= 3) { endSession("볼륨↓ 3회 비상정지"); volCount = 0; }
        }
        return false; // 키 자체는 그대로 전달
    }

    private final Runnable watchdog = new Runnable() {
        @Override public void run() {
            long now = System.currentTimeMillis();
            if (active) {
                if (now > deadline) endSession("시간 만료");
                else if (!paused && now - lastRequest > IDLE_TIMEOUT_MS) endSession("에이전트 응답 없음");
                else updateBanner();
            }
            if (main != null) main.postDelayed(this, 1000);
        }
    };

    // ───────────────────────── 토큰 ─────────────────────────
    static synchronized String token(Context c) {
        File f = new File(c.getFilesDir(), "token");
        try {
            if (f.exists()) {
                byte[] b = new byte[(int) f.length()];
                try (FileInputStream in = new FileInputStream(f)) { int n = in.read(b); return new String(b, 0, Math.max(n, 0), StandardCharsets.US_ASCII).trim(); }
            }
            return regenerateToken(c);
        } catch (Exception e) { return ""; }
    }

    static synchronized String regenerateToken(Context c) {
        byte[] r = new byte[24];
        new SecureRandom().nextBytes(r);
        StringBuilder sb = new StringBuilder();
        for (byte x : r) sb.append(String.format(Locale.US, "%02x", x));
        File f = new File(c.getFilesDir(), "token");
        try (FileOutputStream out = new FileOutputStream(f)) { out.write(sb.toString().getBytes(StandardCharsets.US_ASCII)); } catch (Exception ignored) { }
        return sb.toString();
    }

    // ───────────────────────── 로컬 서버 ─────────────────────────
    private volatile boolean serving;

    /** 서비스가 다시 붙을 때 이전 소켓이 아직 닫히는 중일 수 있어, 열릴 때까지 재시도하고 죽으면 다시 연다. */
    private void startServer() {
        serving = true;
        Thread t = new Thread(() -> {
            while (serving) {
                try (ServerSocket ss = new ServerSocket()) {
                    ss.setReuseAddress(true);
                    ss.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), PORT), 8);
                    server = ss;
                    Log.i(TAG, "listening on 127.0.0.1:" + PORT);
                    while (serving && !ss.isClosed()) {
                        Socket s = ss.accept();
                        new Thread(() -> handleClient(s), "hands-client").start();
                    }
                } catch (Exception e) { Log.w(TAG, "server: " + e); }
                if (serving) try { Thread.sleep(1000); } catch (InterruptedException ie) { return; }
            }
        }, "hands-server");
        t.setDaemon(true);
        t.start();
    }

    private void handleClient(Socket s) {
        JSONObject resp;
        try {
            s.setSoTimeout(15_000);
            BufferedReader r = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8), 8192);
            String line = readLimited(r, 65_536);
            JSONObject req = new JSONObject(line);
            String given = req.optString("token", "");
            if (!MessageDigest.isEqual(given.getBytes(StandardCharsets.US_ASCII), token(this).getBytes(StandardCharsets.US_ASCII))) {
                resp = err("bad token");
            } else {
                resp = dispatch(req);
            }
        } catch (Exception e) {
            resp = err("bad request: " + e.getClass().getSimpleName());
        }
        try (OutputStream out = s.getOutputStream()) {
            out.write((resp.toString() + "\n").getBytes(StandardCharsets.UTF_8));
            out.flush();
        } catch (Exception ignored) { }
        try { s.close(); } catch (Exception ignored) { }
    }

    private static String readLimited(BufferedReader r, int max) throws Exception {
        StringBuilder sb = new StringBuilder();
        int ch;
        while ((ch = r.read()) != -1 && ch != '\n') {
            sb.append((char) ch);
            if (sb.length() > max) throw new IllegalArgumentException("too long");
        }
        return sb.toString();
    }

    // ───────────────────────── 명령 처리 ─────────────────────────
    private JSONObject dispatch(JSONObject q) throws Exception {
        String cmd = q.optString("cmd");
        lastRequest = System.currentTimeMillis();
        switch (cmd) {
            case "status": return status();
            case "start": return start(q);
            case "check": return checkApps(q);   // 확인창 전에 금지 앱 사전 검사 (세션 안 만듦)
            case "apps": return listApps(q);     // 설치된 앱 이름 → 패키지 (홈 화면을 뒤질 필요 없음)
            case "open": return openApp(q);      // 앱 바로 열기 (조작은 안 함 · 금지 앱 제외)
            case "stop": endSession("에이전트 요청"); return ok();
        }
        if (!active) return err("no active session (먼저 hands-start)");
        if (paused && !waitWhilePaused(25_000)) return err("paused").put("paused", true);
        synchronized (actionLock) {
            switch (cmd) {
                case "dump": return dump(q);
                case "click": return click(q);
                case "type": return type(q);
                case "scroll": return scroll(q);
                case "back": return global(GLOBAL_ACTION_BACK, "뒤로");
                case "home": return global(GLOBAL_ACTION_HOME, "홈");
                case "launch": return launch(q);
                case "tap": return tap(q);
                case "swipe": return swipe(q);
                case "run": return run(q);
                case "wait": { int ms = clamp(q.optInt("ms", 1000), 0, 10_000); setStep("기다리는 중"); Thread.sleep(ms); return ok(); }
                default: return err("unknown cmd: " + cmd);
            }
        }
    }

    private JSONObject status() throws Exception {
        JSONObject o = ok().put("session", active).put("paused", paused).put("title", title)
                .put("apps", new JSONArray(allowed)).put("foreground", foreground())
                .put("step_ms", stepMs).put("highlight_ms", highlightMs);
        if (active) o.put("remaining_s", Math.max(0, (deadline - System.currentTimeMillis()) / 1000));
        return o;
    }

    private JSONObject checkApps(JSONObject q) throws Exception {
        JSONArray apps = q.optJSONArray("apps");
        if (apps == null || apps.length() == 0) return err("apps required");
        for (int i = 0; i < apps.length(); i++) {
            String p = apps.getString(i).trim();
            if (!p.matches("[A-Za-z0-9_.]+")) return err("bad package: " + p);
            if (denied(p)) return err("denied package (은행·결제·인증 앱): " + p);
        }
        return ok();
    }

    private JSONObject start(JSONObject q) throws Exception {
        JSONArray apps = q.optJSONArray("apps");
        if (apps == null || apps.length() == 0) return err("apps required");
        Set<String> want = new HashSet<>();
        for (int i = 0; i < apps.length(); i++) {
            String p = apps.getString(i).trim();
            if (!p.matches("[A-Za-z0-9_.]+")) return err("bad package: " + p);
            if (denied(p)) return err("denied package (은행·결제·인증 앱): " + p);
            want.add(p);
        }
        SharedPreferences sp = getSharedPreferences(PREFS, MODE_PRIVATE);
        int minutes = clamp(q.optInt("minutes", 10), 1, 60);
        stepMs = clamp(q.optInt("step_ms", sp.getInt("step_ms", 700)), 150, 5000);
        highlightMs = clamp(q.optInt("highlight_ms", sp.getInt("highlight_ms", 500)), 0, 3000);
        synchronized (allowed) { allowed.clear(); allowed.addAll(want); }
        title = q.optString("title", "자동화");
        if (title.length() > 60) title = title.substring(0, 60);
        deadline = System.currentTimeMillis() + minutes * 60_000L;
        paused = false;
        active = true;
        setStep("시작");
        runOnMain(this::showOverlay);
        return ok().put("minutes", minutes).put("apps", new JSONArray(want));
    }

    private void endSession(String why) {
        if (!active) return;
        active = false;
        paused = false;
        synchronized (allowed) { allowed.clear(); }
        lastDump.clear();
        Log.i(TAG, "session ended: " + why);
        main.post(this::removeOverlay);
    }

    private boolean waitWhilePaused(long maxMs) throws InterruptedException {
        long until = System.currentTimeMillis() + maxMs;
        while (paused && active && System.currentTimeMillis() < until) Thread.sleep(200);
        return !paused && active;
    }

    /** 현재 앞 화면 앱이 세션 허용목록에 있는지. */
    private String checkForeground() {
        String fg = foreground();
        if (fg == null) return "no foreground window";
        if (denied(fg)) return "denied foreground app: " + fg;
        synchronized (allowed) { if (!allowed.contains(fg)) return "foreground app not in session: " + fg; }
        return null;
    }

    private String foreground() {
        AccessibilityNodeInfo root = getRootInActiveWindow();
        return root == null || root.getPackageName() == null ? null : root.getPackageName().toString();
    }

    static boolean denied(String pkg) {
        String p = pkg.toLowerCase(Locale.ROOT);
        for (String d : DENY_SUBSTRINGS) if (p.contains(d)) return true;
        return p.equals("ai.hermesfold7.hands") || p.equals("com.android.settings.security");
    }

    // ── 화면 읽기 ──
    private JSONObject dump(JSONObject q) throws Exception {
        String bad = checkForeground();
        if (bad != null) return err(bad);
        setStep("화면 읽는 중");
        AccessibilityNodeInfo root = getRootInActiveWindow();
        lastDump.clear();
        JSONArray nodes = new JSONArray();
        walk(root, 0, nodes);
        return ok().put("package", foreground()).put("count", nodes.length()).put("nodes", nodes);
    }

    private void walk(AccessibilityNodeInfo n, int depth, JSONArray out) throws Exception {
        if (n == null || lastDump.size() >= MAX_NODES) return;
        if (!n.isVisibleToUser()) { for (int i = 0; i < n.getChildCount(); i++) walk(n.getChild(i), depth + 1, out); return; }
        boolean interesting = n.isClickable() || n.isEditable() || n.isScrollable() || n.isCheckable()
                || !isEmpty(n.getText()) || !isEmpty(n.getContentDescription());
        if (interesting) {
            int idx = lastDump.size();
            lastDump.add(n);
            Rect b = new Rect();
            n.getBoundsInScreen(b);
            JSONObject o = new JSONObject().put("i", idx).put("d", depth)
                    .put("cls", shortCls(n.getClassName()))
                    .put("b", new JSONArray().put(b.left).put(b.top).put(b.right).put(b.bottom));
            if (n.isPassword()) o.put("pw", true);                     // 비밀번호 칸: 내용 절대 반환 안 함
            else if (!isEmpty(n.getText())) o.put("text", cut(n.getText()));
            if (!isEmpty(n.getContentDescription())) o.put("desc", cut(n.getContentDescription()));
            if (n.getViewIdResourceName() != null) o.put("id", n.getViewIdResourceName());
            if (n.isClickable()) o.put("click", true);
            if (n.isEditable()) o.put("edit", true);
            if (n.isScrollable()) o.put("scroll", true);
            if (n.isCheckable()) o.put("checked", n.isChecked());
            out.put(o);
        }
        for (int i = 0; i < n.getChildCount(); i++) walk(n.getChild(i), depth + 1, out);
    }

    // ── 동작 ──
    private AccessibilityNodeInfo target(JSONObject q) {
        if (q.has("i")) {
            int i = q.optInt("i", -1);
            if (i >= 0 && i < lastDump.size()) {
                AccessibilityNodeInfo n = lastDump.get(i);
                if (n.refresh()) return n;
            }
            return null;
        }
        String text = q.optString("text", null);
        String id = q.optString("id", null);
        AccessibilityNodeInfo root = getRootInActiveWindow();
        if (root == null) return null;
        if (q.has("match") || q.optBoolean("edit", false)) {
            Pattern pat = q.has("match") ? Pattern.compile(q.optString("match"), Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE) : null;
            return findMatch(root, pat, q.optBoolean("edit", false), 0);
        }
        List<AccessibilityNodeInfo> found = id != null ? root.findAccessibilityNodeInfosByViewId(id)
                : text != null ? root.findAccessibilityNodeInfosByText(text) : null;
        if (found == null) return null;
        for (AccessibilityNodeInfo n : found) if (n.isVisibleToUser()) return n;
        return null;
    }


    /** 화면 트리에서 정규식(글자·설명·뷰ID)에 맞는 첫 노드. edit=true 면 입력 칸만. */
    private AccessibilityNodeInfo findMatch(AccessibilityNodeInfo n, Pattern pat, boolean editOnly, int depth) {
        if (n == null || depth > 80) return null;
        if (n.isVisibleToUser() && (!editOnly || n.isEditable()) && !n.isPassword()) {
            if (pat == null) { if (editOnly) return n; }
            else for (CharSequence c : new CharSequence[]{n.getText(), n.getContentDescription(), n.getViewIdResourceName()})
                if (c != null && pat.matcher(c).find()) return n;
        }
        for (int i = 0; i < n.getChildCount(); i++) {
            AccessibilityNodeInfo r = findMatch(n.getChild(i), pat, editOnly, depth + 1);
            if (r != null) return r;
        }
        return null;
    }

    // ───────────────────────── 스크립트 실행 (여러 단계를 한 번에) ─────────────────────────
    //  에이전트가 '한 번 클릭 → 다시 묻기'를 반복하지 않고 단계 목록을 한 번에 보내면 앱이 순서대로 실행.
    //  각 단계도 강조·속도·일시정지·허용 앱 검사를 그대로 거침. 실패하면 그 자리에서 멈추고 보고.
    static final int MAX_STEPS = 60;

    private JSONObject run(JSONObject q) throws Exception {
        JSONArray steps = q.optJSONArray("steps");
        if (steps == null || steps.length() == 0) return err("steps required");
        if (steps.length() > MAX_STEPS) return err("too many steps (max " + MAX_STEPS + ")");
        JSONArray report = new JSONArray();
        for (int i = 0; i < steps.length(); i++) {
            if (!active) return err("session ended").put("done", i).put("report", report);
            if (paused && !waitWhilePaused(25_000)) return err("paused").put("paused", true).put("done", i).put("report", report);
            lastRequest = System.currentTimeMillis();                 // 긴 스크립트 중 '유휴 종료' 방지
            JSONObject st = steps.getJSONObject(i);
            String op = st.optString("do");
            JSONObject r;
            try { r = runStep(op, st); } catch (Exception e) { r = err(op + ": " + e.getClass().getSimpleName()); }
            report.put(new JSONObject().put("step", i).put("do", op).put("ok", r.optBoolean("ok")).put("info", r.has("error") ? r.optString("error") : r.optString("clicked", "")));
            if (!r.optBoolean("ok")) {
                if (st.optBoolean("optional", false)) continue;          // 있으면 누르고 없으면 넘어가는 단계 (팝업 닫기 등)
                return err("step " + i + " (" + op + ") failed: " + r.optString("error")).put("done", i).put("report", report);
            }
        }
        return ok().put("done", steps.length()).put("report", report);
    }

    private JSONObject runStep(String op, JSONObject st) throws Exception {
        switch (op) {
            case "click": {
                int tries = clamp(st.optInt("scroll", 0), 0, 10);
                for (int k = 0; ; k++) {
                    JSONObject r = click(st);
                    if (r.optBoolean("ok") || k >= tries) return r;
                    scroll(new JSONObject().put("dir", "down"));
                }
            }
            case "type": return type(st.has("match") || st.has("i") || st.has("id") || st.has("text") ? st : new JSONObject(st.toString()).put("edit", true));
            case "scroll": return scroll(st);
            case "back": return global(GLOBAL_ACTION_BACK, "뒤로");
            case "home": return global(GLOBAL_ACTION_HOME, "홈");
            case "launch": return launch(st);
            case "tap": return tap(st);
            case "swipe": return swipe(st);
            case "wait": { Thread.sleep(clamp(st.optInt("ms", 1000), 0, 10_000)); return ok(); }
            case "wait_for": case "assert": {
                long until = System.currentTimeMillis() + ("assert".equals(op) ? 0 : clamp(st.optInt("ms", 8000), 0, 30_000));
                setStep(("assert".equals(op) ? "확인: " : "기다림: ") + st.optString("match"));
                do {
                    AccessibilityNodeInfo root = getRootInActiveWindow();
                    Pattern pat = Pattern.compile(st.optString("match"), Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE);
                    AccessibilityNodeInfo n = findMatch(root, pat, false, 0);
                    if (n != null) return ok().put("clicked", label(n));
                    Thread.sleep(400);
                } while (System.currentTimeMillis() < until);
                return err("not found: " + st.optString("match"));
            }
            default: return err("unknown step: " + op);
        }
    }

    private JSONObject click(JSONObject q) throws Exception {
        String bad = checkForeground();
        if (bad != null) return err(bad);
        AccessibilityNodeInfo n = target(q);
        if (n == null) return err("node not found (다시 hands-dump)");
        Rect b = new Rect();
        n.getBoundsInScreen(b);
        setStep("누르기: " + label(n));
        showHighlight(b);
        AccessibilityNodeInfo c = n;
        while (c != null && !c.isClickable()) c = c.getParent();
        boolean done = c != null && c.performAction(AccessibilityNodeInfo.ACTION_CLICK);
        if (!done) done = gestureTap(b.centerX(), b.centerY());
        afterStep();
        return done ? ok().put("clicked", label(n)) : err("click failed");
    }

    private JSONObject type(JSONObject q) throws Exception {
        String bad = checkForeground();
        if (bad != null) return err(bad);
        AccessibilityNodeInfo n = target(q);
        if (n == null) return err("node not found");
        if (n.isPassword()) return err("password fields are never typed by the agent");
        if (!n.isEditable()) return err("node is not editable");
        String text = q.optString("value", "");
        if (text.length() > 2000) return err("text too long");
        Rect b = new Rect();
        n.getBoundsInScreen(b);
        setStep("입력: " + cut(text));
        showHighlight(b);
        n.performAction(AccessibilityNodeInfo.ACTION_FOCUS);
        Bundle args = new Bundle();
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text);
        boolean done = n.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args);
        boolean entered = false;
        if (done && q.optBoolean("enter", false)) {          // 주소창·검색창: 입력 후 '이동/검색' 키
            Thread.sleep(Math.min(stepMs, 600));
            setStep("입력 후 Enter");
            if (Build.VERSION.SDK_INT >= 30) {
                n.refresh();
                entered = n.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.getId());
            }
            if (!entered) return err("enter failed (Android 11 이상 필요)");
        }
        afterStep();
        return done ? ok().put("entered", entered) : err("set text failed");
    }

    private JSONObject scroll(JSONObject q) throws Exception {
        String bad = checkForeground();
        if (bad != null) return err(bad);
        boolean down = !"up".equals(q.optString("dir", "down"));
        int act = down ? AccessibilityNodeInfo.ACTION_SCROLL_FORWARD : AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD;
        List<AccessibilityNodeInfo> cands = new ArrayList<>();
        if (q.has("i")) {
            AccessibilityNodeInfo n = target(q);
            if (n == null) return err("node not found");
            cands.add(n);
        } else {
            // 화면의 스크롤 영역을 모두 모아 '가장 안쪽(구체적인) 목록'부터 시도 — 겉 컨테이너는 실제로 안 움직이는 경우가 많음
            collectScrollables(getRootInActiveWindow(), 0, cands);
            if (cands.isEmpty()) return err("no scrollable node");
            Collections.reverse(cands);
        }
        setStep(down ? "아래로 스크롤" : "위로 스크롤");
        for (AccessibilityNodeInfo n : cands) {
            Rect b = new Rect();
            n.getBoundsInScreen(b);
            if (b.width() < 50 || b.height() < 50) continue;
            showHighlight(b);
            if (n.performAction(act)) { afterStep(); return ok(); }
        }
        afterStep();
        return err("scroll failed (끝에 도달했을 수 있음)");
    }

    private void collectScrollables(AccessibilityNodeInfo n, int depth, List<AccessibilityNodeInfo> out) {
        if (n == null || depth > 60) return;
        if (n.isScrollable() && n.isVisibleToUser()) out.add(n);
        for (int i = 0; i < n.getChildCount(); i++) collectScrollables(n.getChild(i), depth + 1, out);
    }

    private JSONObject global(int action, String name) throws Exception {
        setStep(name);
        Thread.sleep(highlightMs);
        boolean done = performGlobalAction(action);
        afterStep();
        return done ? ok() : err(name + " failed");
    }


    /** 실행 가능한 앱 목록: 이름(라벨)·패키지. q 가 있으면 이름/패키지에 포함된 것만. 금지 앱은 표시만 하고 열 수 없음. */
    private JSONObject listApps(JSONObject q) throws Exception {
        String want = q.optString("q", "").trim().toLowerCase(Locale.ROOT);
        PackageManager pm = getPackageManager();
        Intent main = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> ris = pm.queryIntentActivities(main, 0);
        List<JSONObject> rows = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (ResolveInfo ri : ris) {
            String pkg = ri.activityInfo.packageName;
            if (pkg.equals(getPackageName()) || !seen.add(pkg)) continue;
            String label = String.valueOf(ri.loadLabel(pm));
            if (!want.isEmpty() && !label.toLowerCase(Locale.ROOT).contains(want) && !pkg.toLowerCase(Locale.ROOT).contains(want)) continue;
            JSONObject o = new JSONObject().put("name", label).put("package", pkg);
            if (denied(pkg)) o.put("blocked", true);
            rows.add(o);
        }
        rows.sort((a, b) -> a.optString("name").compareToIgnoreCase(b.optString("name")));
        JSONArray out = new JSONArray();
        for (int i = 0; i < rows.size() && i < 80; i++) out.put(rows.get(i));
        return ok().put("count", rows.size()).put("apps", out);
    }

    /** 앱을 열기만 함 (화면 조작 세션 불필요). 은행·결제·인증 앱은 거부. */
    private JSONObject openApp(JSONObject q) throws Exception {
        String pkg = q.optString("package", "");
        if (!pkg.matches("[A-Za-z0-9_.]+")) return err("bad package: " + pkg);
        if (denied(pkg)) return err("denied package (은행·결제·인증 앱): " + pkg);
        Intent it = getPackageManager().getLaunchIntentForPackage(pkg);
        if (it == null) return err("not launchable (설치 안 됨?): " + pkg);
        it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        startActivity(it);
        Thread.sleep(1500);
        return ok().put("opened", pkg).put("foreground", foreground());
    }

    private JSONObject launch(JSONObject q) throws Exception {
        String pkg = q.optString("package", "");
        synchronized (allowed) { if (!allowed.contains(pkg)) return err("package not in session: " + pkg); }
        Intent it = getPackageManager().getLaunchIntentForPackage(pkg);
        if (it == null) return err("not launchable: " + pkg);
        setStep("앱 실행: " + pkg);
        Thread.sleep(highlightMs);
        it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        startActivity(it);
        Thread.sleep(Math.max(stepMs, 1200)); // 앱이 뜰 시간
        return ok().put("foreground", foreground());
    }

    private JSONObject tap(JSONObject q) throws Exception {
        String bad = checkForeground();
        if (bad != null) return err(bad);
        int x = q.getInt("x"), y = q.getInt("y");
        setStep("탭 (" + x + "," + y + ")");
        showHighlight(new Rect(x - 40, y - 40, x + 40, y + 40));
        boolean done = gestureTap(x, y);
        afterStep();
        return done ? ok() : err("tap failed");
    }

    private JSONObject swipe(JSONObject q) throws Exception {
        String bad = checkForeground();
        if (bad != null) return err(bad);
        int x1 = q.getInt("x1"), y1 = q.getInt("y1"), x2 = q.getInt("x2"), y2 = q.getInt("y2");
        int ms = clamp(q.optInt("ms", 400), 100, 3000);
        setStep("스와이프");
        showHighlight(new Rect(x1 - 50, y1 - 50, x1 + 50, y1 + 50));   // 손가락이 닿을 곳을 먼저 보여줌
        Path p = new Path();
        p.moveTo(x1, y1);
        p.lineTo(x2, y2);
        boolean done = gesture(new GestureDescription.StrokeDescription(p, 0, ms), ms + 1000);
        afterStep();
        return done ? ok() : err("swipe failed");
    }

    private boolean gestureTap(int x, int y) throws InterruptedException {
        Path p = new Path();
        p.moveTo(x, y);
        return gesture(new GestureDescription.StrokeDescription(p, 0, 60), 2000);
    }

    /** 좌표 제스처는 보호막을 잠깐 '통과' 상태로 바꾼 뒤 실행하고 즉시 되돌림. */
    private boolean gesture(GestureDescription.StrokeDescription stroke, long timeoutMs) throws InterruptedException {
        // 좌표 제스처 동안만 보호막 창을 잠깐 떼어냄 → 끝나면 바로 다시 붙임.
        // (FLAG_NOT_TOUCHABLE 전환만으로는 일부 기기/버전에서 주입 제스처가 보호막에 흡수됨)
        runOnMain(() -> { if (overlay != null && overlay.isAttachedToWindow()) { try { wm.removeViewImmediate(overlay); } catch (Exception ignored) { } } });
        Thread.sleep(150);
        final boolean[] result = {false};
        final CountDownLatch done = new CountDownLatch(1);
        GestureDescription g = new GestureDescription.Builder().addStroke(stroke).build();
        main.post(() -> {
            boolean sent = dispatchGesture(g, new GestureResultCallback() {
                @Override public void onCompleted(GestureDescription d) { Log.i(TAG, "gesture completed"); result[0] = true; done.countDown(); }
                @Override public void onCancelled(GestureDescription d) { Log.w(TAG, "gesture cancelled"); done.countDown(); }
            }, null);
            Log.i(TAG, "gesture dispatched=" + sent + " overlayAttached=" + (overlay != null && overlay.isAttachedToWindow()));
            if (!sent) done.countDown();
        });
        done.await(timeoutMs, TimeUnit.MILLISECONDS);
        runOnMain(() -> { if (overlay != null && !overlay.isAttachedToWindow() && active) { try { wm.addView(overlay, overlayLp); } catch (Exception e) { Log.w(TAG, "overlay re-add: " + e); } } });
        return result[0];
    }

    private void afterStep() throws InterruptedException {
        Thread.sleep(stepMs);
        main.post(() -> { if (highlight != null) highlight.setVisibility(View.GONE); });
    }

    // ───────────────────────── 보호막 UI ─────────────────────────
    private void showOverlay() {
        if (overlay != null) { updateBanner(); return; }
        Context c = this;
        overlay = new FrameLayout(c);
        GradientDrawable frame = new GradientDrawable();
        frame.setColor(0x1A3D5AFE);
        frame.setStroke(dp(4), 0xCC3D5AFE);
        overlay.setBackground(frame);
        overlay.setOnTouchListener((v, e) -> true); // 사용자 터치 흡수(차단)

        banner = new TextView(c);
        banner.setTextColor(Color.WHITE);
        banner.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        banner.setPadding(dp(14), dp(10), dp(14), dp(10));
        GradientDrawable bb = new GradientDrawable();
        bb.setColor(0xE6111827);
        bb.setCornerRadius(dp(14));
        banner.setBackground(bb);
        FrameLayout.LayoutParams blp = new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        blp.topMargin = dp(48);
        overlay.addView(banner, blp);

        highlight = new View(c);
        GradientDrawable hb = new GradientDrawable();
        hb.setColor(0x33FFC107);
        hb.setStroke(dp(3), 0xFFFFC107);
        hb.setCornerRadius(dp(8));
        highlight.setBackground(hb);
        highlight.setVisibility(View.GONE);
        overlay.addView(highlight, new FrameLayout.LayoutParams(10, 10));

        LinearLayout controls = new LinearLayout(c);
        controls.setOrientation(LinearLayout.VERTICAL);
        controls.setGravity(Gravity.CENTER);
        pauseBtn = roundButton(c, "⏸", 0xE63D5AFE, dp(84));
        pauseBtn.setOnClickListener(v -> setPaused(true));
        resumeBtn = roundButton(c, "▶", 0xE616A34A, dp(84));
        resumeBtn.setOnClickListener(v -> setPaused(false));
        stopBtn = roundButton(c, "■", 0xE6DC2626, dp(64));
        stopBtn.setOnClickListener(v -> endSession("사용자 중지"));
        controls.addView(pauseBtn);
        controls.addView(resumeBtn);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(dp(64), dp(64));
        slp.topMargin = dp(16);
        controls.addView(stopBtn, slp);
        overlay.addView(controls, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));

        overlayLp = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        overlayLp.gravity = Gravity.TOP | Gravity.START;
        wm.addView(overlay, overlayLp);
        applyPausedUi();
        updateBanner();
    }

    private Button roundButton(Context c, String label, int color, int size) {
        Button b = new Button(c);
        b.setText(label);
        b.setTextColor(Color.WHITE);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 26);
        b.setContentDescription("hands-" + (label.equals("⏸") ? "pause" : label.equals("▶") ? "resume" : "stop"));
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.OVAL);
        d.setColor(color);
        b.setBackground(d);
        b.setLayoutParams(new LinearLayout.LayoutParams(size, size));
        return b;
    }

    private void setPaused(boolean p) {
        paused = p;
        if (!p) lastRequest = System.currentTimeMillis();
        applyPausedUi();
        updateBanner();
    }

    private void applyPausedUi() {
        if (overlay == null) return;
        pauseBtn.setVisibility(paused ? View.GONE : View.VISIBLE);
        resumeBtn.setVisibility(paused ? View.VISIBLE : View.GONE);
        stopBtn.setVisibility(paused ? View.VISIBLE : View.GONE);   // 중지는 일시정지 후에만 노출
    }

    private void setOverlayTouchable(boolean touchable) {
        if (overlay == null) return;
        if (touchable) overlayLp.flags &= ~WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
        else overlayLp.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE;
        wm.updateViewLayout(overlay, overlayLp);
    }

    private void showHighlight(Rect b) throws InterruptedException {
        if (highlightMs <= 0) return;
        runOnMain(() -> {
            if (highlight == null) return;
            FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(Math.max(b.width(), dp(24)), Math.max(b.height(), dp(24)));
            lp.leftMargin = b.left;
            lp.topMargin = b.top;
            highlight.setLayoutParams(lp);
            highlight.setVisibility(View.VISIBLE);
        });
        Thread.sleep(highlightMs);
    }

    private void setStep(String s) { step = s; if (main != null) main.post(this::updateBanner); }

    private void updateBanner() {
        if (banner == null || !active) return;
        long left = Math.max(0, (deadline - System.currentTimeMillis()) / 1000);
        String state = paused ? "⏸ 일시정지됨 — ▶ 재개 / ■ 중지" : "🤖 Hermes 자동화 중";
        banner.setText(state + " · " + title + "\n" + step + " · 남은 " + (left / 60) + "분 " + (left % 60) + "초 · 볼륨↓×3 비상정지");
    }

    private void removeOverlay() {
        if (overlay != null) {
            try { wm.removeView(overlay); } catch (Exception ignored) { }
        }
        overlay = null; banner = null; highlight = null;
    }

    // ───────────────────────── 유틸 ─────────────────────────
    private void runOnMain(Runnable r) throws InterruptedException {
        if (Looper.myLooper() == Looper.getMainLooper()) { r.run(); return; }
        CountDownLatch l = new CountDownLatch(1);
        main.post(() -> { try { r.run(); } finally { l.countDown(); } });
        l.await(3, TimeUnit.SECONDS);
    }

    private int dp(int v) { return Math.round(v * getResources().getDisplayMetrics().density); }
    private static int clamp(int v, int lo, int hi) { return Math.max(lo, Math.min(hi, v)); }
    private static boolean isEmpty(CharSequence s) { return s == null || s.length() == 0; }
    private static String cut(CharSequence s) { String t = s.toString(); return t.length() > 120 ? t.substring(0, 120) + "…" : t; }
    private static String shortCls(CharSequence c) { if (c == null) return ""; String s = c.toString(); return s.substring(s.lastIndexOf('.') + 1); }
    private static String label(AccessibilityNodeInfo n) {
        if (!n.isPassword() && !isEmpty(n.getText())) return cut(n.getText());
        if (!isEmpty(n.getContentDescription())) return cut(n.getContentDescription());
        return n.getViewIdResourceName() != null ? n.getViewIdResourceName() : shortCls(n.getClassName());
    }
    private static JSONObject ok() throws Exception { return new JSONObject().put("ok", true); }
    private static JSONObject err(String m) { try { return new JSONObject().put("ok", false).put("error", m); } catch (Exception e) { return new JSONObject(); } }
}
