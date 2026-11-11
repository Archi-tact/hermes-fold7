// lab/fold/fold-e2e.js — Hermes Fold 화면을 실제 Hermes 서버 + 실제 모델로 종단 테스트 (Playwright)
//   env: FOLD_URL(http://127.0.0.1:9130) FOLD_PASSWORD  ART_DIR(스크린샷 저장)  HAS_KEY(1이면 모델 대화까지)
const { chromium } = require("playwright");
const fs = require("fs");
const URL0 = process.env.FOLD_URL || "http://127.0.0.1:9130";
const ART = process.env.ART_DIR || ".";
const SHOTS = `${ART}/shots`; fs.mkdirSync(SHOTS, { recursive: true });
let pass = 0, fail = 0, n = 0;
const ok = (m) => { console.log("OK   " + m); pass++; };
const bad = (m) => { console.log("FAIL " + m); fail++; };
const shot = (p, name) => p.screenshot({ path: `${SHOTS}/${String(++n).padStart(2, "0")}-${name}.png` });

async function waitTurn(page, ms = 240000) {   // 답변이 끝날 때까지 (보내기 버튼이 다시 ↑)
  await page.waitForFunction(() => document.querySelector("#send") && !document.querySelector("#send").classList.contains("stop"), null, { timeout: ms });
}

(async () => {
  const browser = await chromium.launch();
  // Galaxy Z Fold7 커버 화면 근사치 (CSS 384×860, DPR 2.8)
  const ctx = await browser.newContext({ viewport: { width: 384, height: 860 }, deviceScaleFactor: 2.8, isMobile: true, hasTouch: true, colorScheme: "dark", locale: "ko-KR" });
  const page = await ctx.newPage();
  const errs = []; page.on("pageerror", (e) => errs.push(e.message));

  console.log("== 1. 로그인 없이는 못 들어옴");
  const anon = await ctx.request.get(URL0 + "/", { maxRedirects: 0 });
  const anonBody = await anon.text();
  console.log(`   익명 GET / → ${anon.status()}`);
  (anon.status() >= 300 || /login|sign in|로그인/i.test(anonBody)) && !/__HERMES_SESSION_TOKEN__="/.test(anonBody)
    ? ok(`로그인 필수 (익명 접근 ${anon.status()}, 토큰 노출 없음)`) : bad("익명 접근이 허용됨");
  const t = await ctx.request.post(URL0 + "/api/auth/ws-ticket");
  t.status() === 401 || t.status() === 403 ? ok(`로그인 없이 실시간 연결 티켓 발급 거부 (${t.status()})`) : bad(`티켓 발급 ${t.status()}`);
  const wrong = await ctx.request.post(URL0 + "/auth/password-login", { data: { provider: "basic", username: "fold", password: "wrong-password", next: "/" } });
  wrong.status() === 401 ? ok("틀린 비밀번호 거부 (401)") : bad(`틀린 비밀번호 ${wrong.status()}`);
  const upAnon = await ctx.request.post(URL0 + "/api/plugins/fold-upload/upload?name=x.txt", { data: Buffer.from("x"), headers: { "Content-Type": "application/octet-stream" } });
  upAnon.status() === 401 || upAnon.status() === 403 ? ok(`로그인 없이 파일 업로드 거부 (${upAnon.status()})`) : bad(`익명 업로드 ${upAnon.status()}`);

  console.log("== 2. 비밀번호 로그인 → Hermes Fold 화면");
  const login = await ctx.request.post(URL0 + "/auth/password-login", { data: { provider: "basic", username: "fold", password: process.env.FOLD_PASSWORD, next: "/" } });
  login.ok() ? ok("비밀번호 로그인") : bad(`로그인 ${login.status()} ${await login.text()}`);
  const up = await ctx.request.post(URL0 + "/api/plugins/fold-upload/upload?name=" + encodeURIComponent("../메모 1.txt"), { data: Buffer.from("hello fold"), headers: { "Content-Type": "application/octet-stream" } });
  const upj = await up.json().catch(() => ({}));
  up.ok() && /\/uploads\/[^/]*메모_1\.txt$/.test(upj.path || "") && upj.size === 10
    ? ok("파일 첨부 업로드 → 작업 폴더 uploads/ (이름 정리 · 경로 밖으로 못 나감)") : bad(`업로드 ${up.status()} ${JSON.stringify(upj)}`);
  await page.goto(URL0 + "/");
  await page.waitForSelector("#conn.on", { timeout: 60000 }).then(() => ok("실시간 연결 (/api/ws, 1회용 티켓)")).catch(async () => { bad("실시간 연결 안 됨"); });
  await page.waitForTimeout(1500);
  const title = await page.title();
  title === "Hermes Fold" ? ok("Hermes Fold 화면 표시") : bad("화면 제목: " + title);
  await shot(page, "cover-start");

  console.log("== 2b. 첫 실행: 화면에서 API 키 입력 (터미널 없이)");
  const sheet = await page.waitForSelector("#setup.on", { timeout: 20000 }).catch(() => null);
  sheet ? ok("API 키가 없으면 첫 실행 설정 화면이 자동으로 뜸") : bad("첫 실행 설정 화면 안 뜸");
  await shot(page, "cover-setup");
  if (sheet && process.env.HAS_KEY === "1") {
    await page.click('.prov[data-id="nvidia"]');
    await page.fill("#apiKey", process.env.NVIDIA_API_KEY);
    await page.fill("#modelName", process.env.NVIDIA_MODEL || "nvidia/nemotron-3-ultra-550b-a55b");
    await page.click("#setupSave");
    const saved = await page.waitForSelector("#setupMsg.ok", { timeout: 30000 }).catch(() => null);
    saved ? ok("API 키 · 모델 저장 (Hermes 공식 설정 API)") : bad("저장 실패: " + await page.textContent("#setupMsg"));
    await page.waitForSelector("#setup.on", { state: "detached", timeout: 5000 }).catch(() => {});
    await page.waitForTimeout(2000);
    const m = await page.textContent("#model");
    /nemotron/.test(m) ? ok("상단에 선택한 모델 표시: " + m.trim()) : bad("모델 표시: " + m);
    // 다시 열어도 키가 '저장됨' 으로 인식되는지 (새로고침 후 설정 화면이 자동으로 안 떠야 함)
    await page.reload(); await page.waitForSelector("#conn.on", { timeout: 60000 }).catch(() => {});
    await page.waitForTimeout(3000);
    (await page.locator("#setup.on").count()) === 0 ? ok("새로고침 후에도 설정 유지 (다시 묻지 않음)") : bad("설정 화면이 또 뜸");
  }

  console.log("== 2c. 추론 강도 버튼 (🧠) → Hermes 설정에 저장 · 새로고침 후 유지");
  await page.evaluate(() => document.getElementById("setup").classList.remove("on"));
  await page.click("#effort");
  const effs = await page.locator("#efforts .eff").count();
  effs >= 3 ? ok("추론 강도 선택지 " + effs + "개") : bad("선택지 " + effs);
  await shot(page, "cover-effort");
  await page.click('#efforts .eff[data-v="low"]');
  await page.waitForSelector("#effortMsg.ok", { timeout: 15000 }).then(() => ok("빠르게(low) 적용"))
    .catch(async () => bad("적용 실패: " + await page.textContent("#effortMsg")));
  await page.reload(); await page.waitForSelector("#conn.on", { timeout: 60000 }).catch(() => {});
  await page.waitForFunction(() => /빠르게/.test(document.getElementById("effort").textContent), null, { timeout: 15000 })
    .then(() => ok("새로고침 후에도 빠르게 유지 (설정 파일에 저장됨)")).catch(async () => bad("유지 안 됨: " + await page.textContent("#effort")));
  await page.evaluate(() => document.getElementById("setup").classList.remove("on"));

  if (process.env.HAS_KEY === "1") {
    console.log("== 3. 실제 모델과 대화 (스트리밍)");
    await page.fill("#input", "안녕! 한 문장으로 너를 소개해줘.");
    await page.click("#send");
    await page.waitForSelector("#send.stop", { timeout: 15000 }).catch(() => {});
    await waitTurn(page).catch(() => {});
    const ai = (await page.locator(".msg.ai").allTextContents()).join(" ").trim();
    console.log("   답: " + ai.slice(0, 120));
    ai.length > 5 ? ok("모델 답변이 화면에 스트리밍됨") : bad("답변 없음");
    await shot(page, "cover-chat");

    console.log("== 4. 도구 실행 카드 (터미널 명령)");
    await page.fill("#input", "terminal 도구로 `echo hermes-fold-ok` 명령을 꼭 실제로 실행하고, 출력된 글자만 그대로 알려줘.");
    await page.click("#send");
    await waitTurn(page).catch(() => {});
    const tools = await page.locator(".tool").count();
    const okTools = await page.locator(".tool .ts.ok").count();
    tools > 0 && okTools > 0 ? ok(`도구 실행 카드 표시 (${okTools}/${tools} 완료)`) : bad(`도구 카드 ${okTools}/${tools}`);
    const allText = (await page.locator(".msg.ai").allTextContents()).join(" ");
    /hermes-fold-ok/.test(allText) ? ok("명령 결과를 답변에 반영") : bad("결과 문자열 없음");
    if (tools > 0) await page.locator(".tool").first().click().catch(() => {});   // 카드 펼쳐 보기
    await shot(page, "cover-tool");

    console.log("== 5. 위험 명령 → 화면에서 승인 카드");
    await page.fill("#input", "터미널에서 `rm -rf /tmp/hermes-fold-approval-test` 를 실행해줘. 승인이 필요하면 요청해.");
    await page.click("#send");
    const ask = await page.waitForSelector(".ask", { timeout: 180000 }).catch(() => null);
    if (ask) {
      ok("승인 요청 카드 표시 (서버→화면 요청)");
      await shot(page, "cover-approval");
      await page.click(".ask .btn.pri");
      await waitTurn(page).catch(() => {});
      (await page.locator(".ask.done").count()) > 0 ? ok("'이번만 허용' 응답 전달 → 작업 계속") : bad("승인 응답 반영 안 됨");
    } else {
      console.log("   (모델이 명령을 실행하지 않았거나 승인 없이 처리됨 — 승인 카드 검사는 건너뜀)");
      await waitTurn(page).catch(() => {});
    }

    console.log("== 5b. 답변 도중 화면을 닫았다가 다시 열기 → 답변이 이어서 보임");
    await page.fill("#input", "1부터 5까지 한 줄에 하나씩 숫자만 써줘.");
    await page.click("#send");
    await page.waitForTimeout(1500);
    await page.close();                                   // 앱을 내리거나 닫은 상황
    await new Promise((r) => setTimeout(r, 30000));       // 그 사이 서버는 계속 일함
    const back = await ctx.newPage();
    await back.goto(URL0 + "/");
    await back.waitForSelector("#conn.on", { timeout: 60000 }).catch(() => {});
    await back.waitForFunction(() => /[1-5][\s\S]*5/.test([...document.querySelectorAll(".msg.ai")].map((e) => e.textContent).join(" ")), null, { timeout: 120000 })
      .then(() => ok("다시 열면 닫혀 있던 동안의 답변이 이어서 보임")).catch(async () => { bad("닫았다 연 뒤 답변 안 보임"); });
    await back.waitForTimeout(500); await shot(back, "cover-reopened");

    console.log("== 6. 펼친 화면(3단) + 대화 이어보기");
    const wide = await browser.newContext({ viewport: { width: 884, height: 940 }, deviceScaleFactor: 2.2, colorScheme: "dark", locale: "ko-KR", storageState: await ctx.storageState() });
    const p2 = await wide.newPage();
    await p2.goto(URL0 + "/");
    await p2.waitForSelector("#conn.on", { timeout: 60000 }).catch(() => {});
    await p2.waitForTimeout(2500);
    if (await p2.locator("#openSide").isVisible()) await p2.click("#openSide");   // 펼친 폴드(세로): 목록은 서랍
    await p2.waitForTimeout(800);
    const items = await p2.locator(".sitem").count();
    items > 0 ? ok(`대화 목록 ${items}개`) : bad("대화 목록 비어 있음");
    await p2.locator(".sitem").first().click().catch(() => {});
    await p2.waitForTimeout(3000);
    (await p2.locator(".msg.user").count()) > 0 ? ok("이전 대화 불러오기 (session.resume)") : bad("이전 대화 불러오기");
    (await p2.locator("#phone").isVisible()) ? ok("펼친 화면에서 대화 + 폰 패널 2단 표시") : bad("폰 패널 안 보임");
    await shot(p2, "unfolded");
  } else {
    console.log("   (NVIDIA_API_KEY 없음 → 모델 대화 검사 생략)");
  }
  errs.length ? bad("화면 JS 오류: " + errs.join(" | ")) : ok("화면 JS 오류 없음");
  await browser.close();
  console.log(`\nRESULT: PASS=${pass} FAIL=${fail}  (Hermes Fold 화면)`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); console.log(`\nRESULT: PASS=${pass} FAIL=${fail + 1}`); process.exit(1); });
