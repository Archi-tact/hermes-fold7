package ai.hermesfold7.hands;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputType;
import android.util.TypedValue;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/** 설정 화면: 접근성 켜기, 연결 토큰(Termux에 붙여넣기), 동작 속도. */
public class MainActivity extends Activity {
    private TextView status, tokenView;
    private boolean tokenShown = false;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        int pad = dp(20);
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(pad, pad, pad, pad);

        col.addView(text("Hermes Hands", 24));
        col.addView(text("Hermes 에이전트가 승인된 자동화 세션 동안에만 앱 화면을 읽고 조작합니다. "
                + "세션 중에는 보호막이 씌워져 가운데 ⏸ 버튼 외 터치가 막힙니다. "
                + "은행·결제·인증 앱과 비밀번호 칸은 항상 제외됩니다.", 14));

        status = text("", 16);
        col.addView(status);
        Button a11y = new Button(this);
        a11y.setText("1. 접근성 설정 열기 → 'Hermes Hands' 켜기");
        a11y.setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)));
        col.addView(a11y);

        col.addView(text("2. 연결 토큰 — 복사해서 Termux에서: phone-hands-pair <토큰>", 14));
        tokenView = text("••••••••", 14);
        tokenView.setTextIsSelectable(true);
        col.addView(tokenView);
        Button show = new Button(this);
        show.setText("토큰 보기/숨기기");
        show.setOnClickListener(v -> { tokenShown = !tokenShown; refresh(); });
        col.addView(show);
        Button copy = new Button(this);
        copy.setText("토큰 복사");
        copy.setOnClickListener(v -> {
            ClipboardManager cm = getSystemService(ClipboardManager.class);
            cm.setPrimaryClip(ClipData.newPlainText("hands token", HandsService.token(this)));
            Toast.makeText(this, "복사됨 — Termux에 붙여넣은 뒤 클립보드를 비우세요", Toast.LENGTH_LONG).show();
        });
        col.addView(copy);
        Button regen = new Button(this);
        regen.setText("토큰 새로 만들기 (기존 연결 끊김)");
        regen.setOnClickListener(v -> { HandsService.regenerateToken(this); refresh(); });
        col.addView(regen);

        SharedPreferences sp = getSharedPreferences(HandsService.PREFS, MODE_PRIVATE);
        col.addView(text("3. 동작 속도 (ms) — 한 단계 후 쉬는 시간 / 누를 곳 표시 시간", 14));
        EditText step = number(sp.getInt("step_ms", 700));
        EditText hl = number(sp.getInt("highlight_ms", 500));
        col.addView(step);
        col.addView(hl);
        Button save = new Button(this);
        save.setText("속도 저장");
        save.setOnClickListener(v -> {
            sp.edit().putInt("step_ms", parse(step, 700)).putInt("highlight_ms", parse(hl, 500)).apply();
            Toast.makeText(this, "저장됨 (다음 세션부터 적용)", Toast.LENGTH_SHORT).show();
        });
        col.addView(save);

        ScrollView sv = new ScrollView(this);
        sv.addView(col);
        setContentView(sv);
    }

    @Override
    protected void onResume() { super.onResume(); refresh(); }

    private void refresh() {
        boolean on = HandsService.get() != null;
        status.setText(on ? "● 접근성 서비스 켜짐 (127.0.0.1:" + HandsService.PORT + ")" : "○ 접근성 서비스 꺼짐 — 아래 1번으로 켜세요");
        String t = HandsService.token(this);
        tokenView.setText(tokenShown ? t : "••••••••" + (t.length() > 4 ? t.substring(t.length() - 4) : ""));
    }

    private TextView text(String s, int sp) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        t.setPadding(0, dp(8), 0, dp(8));
        return t;
    }

    private EditText number(int v) {
        EditText e = new EditText(this);
        e.setInputType(InputType.TYPE_CLASS_NUMBER);
        e.setText(String.valueOf(v));
        return e;
    }

    private static int parse(EditText e, int def) {
        try { return Integer.parseInt(e.getText().toString().trim()); } catch (Exception x) { return def; }
    }

    private int dp(int v) { return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics())); }
}
