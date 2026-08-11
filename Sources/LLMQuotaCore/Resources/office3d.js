/* 数字员工工位实况 —— 低多边形 3D 场景。
 *
 * 造型是程序化生成的，不是导入的美术资产：每个平台的配色、每种状态的姿态
 * 都由数据算出来。这样看板重新生成一次，人物就跟着最新数据变，
 * 不需要维护一套模型文件和导出流程。
 *
 * 动作绑的是真实数据，不是随机播放：
 *   - 敲键盘的快慢 = 该平台最近的调用频率
 *   - 前倾发抖     = 额度逼近上限
 *   - 趴在桌上     = 额度已耗尽
 *   - 靠着打盹     = 产能在闲置
 *   - 工位空着     = 在编但没上岗
 */
(function () {
  "use strict";

  var T = window.THREE;
  if (!T) return;

  var REDUCED = window.matchMedia &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---- 造人

  function boxMat(colorHex, opts) {
    opts = opts || {};
    return new T.MeshStandardMaterial({
      color: new T.Color(colorHex),
      roughness: opts.roughness === undefined ? 0.75 : opts.roughness,
      metalness: opts.metalness === undefined ? 0.05 : opts.metalness,
      transparent: !!opts.transparent,
      opacity: opts.opacity === undefined ? 1 : opts.opacity
    });
  }

  function mesh(geo, mat, x, y, z) {
    var m = new T.Mesh(geo, mat);
    m.position.set(x || 0, y || 0, z || 0);
    m.castShadow = true;
    m.receiveShadow = true;
    return m;
  }

  /// 一个工位：桌子 + 显示器 + 椅子 + 人。
  function buildStation(hue, state) {
    var g = new T.Group();
    var absent = state === "absent";
    var skin = boxMat(0xD9C3A5);
    var body = boxMat(hue, { roughness: 0.6 });
    var dark = boxMat(0x2B3438);

    // 桌
    var desk = mesh(new T.BoxGeometry(2.2, 0.11, 1.15), boxMat(0x8A7256), 0, 1.0, 0);
    g.add(desk);
    [[-0.95, 0.44], [0.95, 0.44], [-0.95, -0.44], [0.95, -0.44]].forEach(function (p) {
      g.add(mesh(new T.BoxGeometry(0.1, 1.0, 0.1), boxMat(0x6E5A44), p[0], 0.5, p[1]));
    });

    // 显示器侧放在桌角。
    //
    // 人坐在桌子**后面**面朝镜头，所以屏幕是背对我们的 —— 这是对的，
    // 因为看得见脸和敲键盘的手，比看见屏幕内容重要得多。
    // 屏幕开没开机改由机身背板发光来表达，等于把光溢出画出来。
    var screenMat = new T.MeshStandardMaterial({
      color: new T.Color(0x11181C),
      emissive: new T.Color(hue),
      emissiveIntensity: absent ? 0 : 0.6,
      roughness: 0.4
    });
    var backMat = new T.MeshStandardMaterial({
      color: new T.Color(0x323C41),
      emissive: new T.Color(hue),
      emissiveIntensity: absent ? 0 : 0.1,
      roughness: 0.6
    });
    var monitor = new T.Group();
    monitor.add(mesh(new T.BoxGeometry(0.82, 0.5, 0.05), backMat, 0, 0, 0));
    var screen = mesh(new T.PlaneGeometry(0.7, 0.4), screenMat, 0, 0, -0.035);
    screen.rotation.y = Math.PI;   // 屏幕面朝坐着的人
    screen.castShadow = false;
    monitor.add(screen);
    monitor.add(mesh(new T.BoxGeometry(0.08, 0.2, 0.08), dark, 0, -0.35, 0));
    monitor.add(mesh(new T.BoxGeometry(0.34, 0.035, 0.2), dark, 0, -0.45, 0));
    monitor.position.set(0.72, 1.55, -0.2);
    monitor.rotation.y = -0.62;
    g.add(monitor);

    // 键盘放在人的正前方
    g.add(mesh(new T.BoxGeometry(0.9, 0.05, 0.3), dark, -0.3, 1.09, -0.3));

    // 椅子在人的更后面
    var chair = new T.Group();
    chair.add(mesh(new T.BoxGeometry(0.8, 0.1, 0.8), dark, 0, 0.62, 0));
    chair.add(mesh(new T.BoxGeometry(0.8, 0.9, 0.1), dark, 0, 1.05, 0.38));
    chair.add(mesh(new T.CylinderGeometry(0.07, 0.07, 0.6, 8), dark, 0, 0.3, 0));
    chair.position.set(0, 0, -1.35);
    g.add(chair);

    var parts = {
      screen: screen, screenMat: screenMat, backMat: backMat, monitor: monitor
    };

    if (absent) {
      // 没上岗就是没人 —— 空工位本身就是最清楚的表达，不要放个灰人。
      parts.person = null;
      return { group: g, parts: parts };
    }

    // 人
    var person = new T.Group();
    var torso = mesh(new T.CapsuleGeometry(0.32, 0.42, 4, 10), body, 0, 1.42, 0);
    person.add(torso);

    var head = new T.Group();
    head.add(mesh(new T.BoxGeometry(0.56, 0.5, 0.5), skin, 0, 0, 0));
    // 眼睛：两个小方块，趴下/打盹时会被姿态挡住，不用单独做表情
    head.add(mesh(new T.BoxGeometry(0.09, 0.09, 0.04), dark, -0.14, 0.03, 0.26));
    head.add(mesh(new T.BoxGeometry(0.09, 0.09, 0.04), dark, 0.14, 0.03, 0.26));
    head.add(mesh(new T.BoxGeometry(0.6, 0.16, 0.54), body, 0, 0.3, 0));
    head.position.set(0, 1.98, 0);
    person.add(head);

    var armGeo = new T.CapsuleGeometry(0.1, 0.34, 4, 8);
    var armL = mesh(armGeo, body, -0.4, 1.42, 0.2);
    var armR = mesh(armGeo, body, 0.4, 1.42, 0.2);
    armL.rotation.x = -0.9; armR.rotation.x = -0.9;
    person.add(armL); person.add(armR);

    // 人坐在桌子后面（更远离镜头），面朝镜头。放大到成为画面主体 ——
    // 这张图要传达的是「谁在干活」，不是「桌子长什么样」。
    person.position.set(0, 0, -0.95);
    person.scale.setScalar(1.22);
    g.add(person);

    parts.person = person;
    parts.head = head;
    parts.torso = torso;
    parts.armL = armL;
    parts.armR = armR;
    return { group: g, parts: parts };
  }

  // ---- 各状态的姿态与动作

  // 屏幕正面背对镜头，所以"开没开机"要靠机身背板的光溢出来表达，
  // 两块材质得一起改，只改屏幕的话从我们这个角度根本看不出来。
  function glow(p, intensity, colorHex) {
    p.screenMat.emissiveIntensity = intensity;
    if (p.backMat) p.backMat.emissiveIntensity = intensity * 0.16;
    if (colorHex !== undefined) {
      p.screenMat.emissive.setHex(colorHex);
      if (p.backMat) p.backMat.emissive.setHex(colorHex);
    }
  }

  function applyState(e, t) {
    var p = e.parts, s = e.state, act = e.activity;
    if (!p.person) return;

    var armL = p.armL, armR = p.armR, head = p.head, torso = p.torso;
    // 静止时也要摆出能读出状态的姿态，动画只是让它活起来。
    var time = REDUCED ? 0 : t;

    if (s === "working" || s === "strained") {
      // 敲键盘的频率直接来自真实调用频率，忙的人手速就是快。
      var speed = (s === "strained" ? 11 : 5) + act * 9;
      armL.rotation.x = -0.9 + Math.sin(time * speed) * 0.16;
      armR.rotation.x = -0.9 + Math.sin(time * speed + Math.PI) * 0.16;
      head.rotation.x = 0.14 + Math.sin(time * speed * 0.5) * 0.03;
      glow(p, 0.55 + Math.abs(Math.sin(time * 2.2)) * 0.35);

      if (s === "strained") {
        // 逼近上限：身体前倾 + 细微发抖 + 屏幕泛红
        torso.rotation.x = 0.2;
        p.person.position.x = Math.sin(time * 28) * 0.012;
        glow(p, 0.75 + Math.abs(Math.sin(time * 6)) * 0.5, 0xC4483C);
      } else {
        torso.rotation.x = 0.06;
        p.person.position.x = 0;
      }
    } else if (s === "drained") {
      // 额度烧穿：趴在桌上，屏幕熄了
      torso.rotation.x = 1.05;
      p.person.position.y = -0.18;
      head.rotation.x = 0.5;
      head.position.y = 1.72;
      armL.rotation.x = -1.5; armR.rotation.x = -1.5;
      armL.position.y = 1.15; armR.position.y = 1.15;
      glow(p, 0.05);
      // 还有呼吸，说明只是耗尽不是宕机
      torso.scale.y = 1 + Math.sin(time * 1.1) * 0.012;
    } else {
      // 产能闲置：靠着椅背打盹
      torso.rotation.x = -0.18;
      head.rotation.x = -0.1 + Math.sin(time * 0.8) * 0.05;
      armL.rotation.x = -0.2; armR.rotation.x = -0.2;
      armL.position.z = 0.05; armR.position.z = 0.05;
      glow(p, 0.12 + Math.abs(Math.sin(time * 0.6)) * 0.06);
      torso.scale.y = 1 + Math.sin(time * 0.9) * 0.02;
    }
  }

  // ---- 挂载

  function mount(container, roster, opts) {
    opts = opts || {};
    var renderer;
    try {
      renderer = new T.WebGLRenderer({ antialias: true, alpha: true });
    } catch (err) {
      return null; // 没有 WebGL 就让调用方退回 2D
    }

    var scene = new T.Scene();
    var camera = new T.PerspectiveCamera(38, 1, 0.1, 100);

    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = T.PCFSoftShadowMap;
    renderer.outputColorSpace = T.SRGBColorSpace;
    container.appendChild(renderer.domElement);
    renderer.domElement.style.display = "block";
    renderer.domElement.style.width = "100%";
    renderer.domElement.style.height = "100%";

    scene.add(new T.HemisphereLight(0xE9EDEC, 0x30403F, 1.05));
    var key = new T.DirectionalLight(0xFFF6E8, 1.5);
    key.position.set(4, 8, 6);
    key.castShadow = true;
    key.shadow.mapSize.set(1024, 1024);
    key.shadow.camera.left = -12; key.shadow.camera.right = 12;
    key.shadow.camera.top = 8; key.shadow.camera.bottom = -6;
    scene.add(key);
    scene.add(new T.AmbientLight(0xffffff, 0.28));

    // 地面只收阴影，不画颜色，这样页面背景（含深色主题）能直接透上来。
    var floor = new T.Mesh(
      new T.PlaneGeometry(80, 40),
      new T.ShadowMaterial({ opacity: 0.16 })
    );
    floor.rotation.x = -Math.PI / 2;
    floor.receiveShadow = true;
    scene.add(floor);

    var employees = [];
    var spacing = 3.4;
    var offset = (roster.length - 1) * spacing / 2;

    roster.forEach(function (r, i) {
      var built = buildStation(r.hue, r.state);
      built.group.position.x = i * spacing - offset;
      built.group.rotation.y = -0.22;
      scene.add(built.group);
      employees.push({
        parts: built.parts,
        group: built.group,
        state: r.state,
        activity: Math.max(0, Math.min(1, r.activity || 0)),
        name: r.name
      });
    });

    // 名牌用 DOM 而不是 3D 文字：中文字形在 3D 里要么糊要么得塞字体文件。
    var labels = roster.map(function (r) {
      var el = document.createElement("div");
      el.className = "office-label";
      el.textContent = r.name;
      container.appendChild(el);
      return el;
    });

    var v = new T.Vector3();
    function layoutLabels() {
      var rect = renderer.domElement.getBoundingClientRect();
      employees.forEach(function (e, i) {
        v.set(e.group.position.x, 0.15, e.group.position.z);
        v.project(camera);
        labels[i].style.left = ((v.x * 0.5 + 0.5) * rect.width) + "px";
        labels[i].style.top = ((-v.y * 0.5 + 0.5) * rect.height) + "px";
      });
    }

    function resize() {
      var w = container.clientWidth;
      var h = container.clientHeight;
      if (!w || !h) return;
      renderer.setSize(w, h, false);
      camera.aspect = w / h;

      // 按视锥真实解算距离，而不是拿"人数 × 间距"去估。
      // 估算会严重过远：5 个人时估出来是 16 个单位，画面里人只占中间一小块，
      // 动作全看不清。这里横竖两个方向分别求出"刚好装下"的距离，取较大的那个。
      var contentW = (roster.length - 1) * spacing + 3.2;
      var contentH = 3.4;
      var vFov = camera.fov * Math.PI / 180;
      var hFov = 2 * Math.atan(Math.tan(vFov / 2) * camera.aspect);
      var distW = (contentW / 2) / Math.tan(hFov / 2);
      var distH = (contentH / 2) / Math.tan(vFov / 2);
      var dist = Math.max(distW, distH) * 1.1 + 1.6;

      // 视高压到接近人眼，比俯视更像"看着同事在工位上干活"。
      camera.position.set(0, 2.5, dist);
      camera.lookAt(0, 1.35, 0);
      camera.updateProjectionMatrix();
      layoutLabels();
    }

    var clock = new T.Clock();
    function frame() {
      var t = clock.getElapsedTime();
      employees.forEach(function (e) { applyState(e, t); });
      renderer.render(scene, camera);
      if (!REDUCED) requestAnimationFrame(frame);
    }

    resize();
    if (window.ResizeObserver) new ResizeObserver(resize).observe(container);
    else window.addEventListener("resize", resize);

    if (REDUCED) {
      // 关掉动效也要看到正确的姿态，所以仍然应用一次状态再渲染。
      employees.forEach(function (e) { applyState(e, 0); });
      renderer.render(scene, camera);
      layoutLabels();
    } else {
      frame();
    }

    return { renderer: renderer, resize: resize };
  }

  window.LLMQOffice = { mount: mount };
})();
