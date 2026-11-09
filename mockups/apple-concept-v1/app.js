(() => {
  'use strict';
  const icon = name => `<i data-lucide="${name}" aria-hidden="true"></i>`;
  const products = [
    { id: 'milk', name: '有机纯牛奶', category: '食品', count: 3, unit: '盒', location: '厨房 · 冷藏区', expiry: '3 天后到期', art: 'milk', tone: '#e9eddf', group: '食品饮料' },
    { id: 'vitamin', name: '维生素 C', category: '健康', count: 1, unit: '瓶', location: '客厅 · 药品抽屉', expiry: '14 天后到期', art: 'bottle', tone: '#ede8dc', group: '健康护理' },
    { id: 'oats', name: '原味燕麦片', category: '食品', count: 2, unit: '罐', location: '厨房 · 储物柜', expiry: '效期充足', art: 'jar', tone: '#e9e6db', group: '食品饮料' },
    { id: 'soap', name: '植物洗手液', category: '日用', count: 1, unit: '瓶', location: '浴室 · 洗手台', expiry: '库存偏低', art: 'soap', tone: '#e4e7e0', group: '家居日用' },
    { id: 'oatmilk', name: '原味燕麦奶', category: '食品', count: 2, unit: '盒', location: '厨房 · 冷藏区', expiry: '效期充足', art: 'milk blue', tone: '#e2e9e8', group: '食品饮料' },
    { id: 'handsoap', name: '备用洗手液', category: '日用', count: 2, unit: '瓶', location: '浴室 · 储物柜', expiry: '效期充足', art: 'soap', tone: '#e9e4d9', group: '家居日用' },
  ];
  const initialShopping = [
    { id: 1, name: '厨房纸巾', amount: '2 提', group: '家居日用', note: '库存偏低 · 家里剩 1 卷', done: false },
    { id: 2, name: '植物洗手液', amount: '1 瓶', group: '家居日用', note: '库存偏低 · 家里剩 1 瓶', done: false },
    { id: 3, name: '鸡蛋', amount: '1 盒', group: '食品饮料', note: '早餐常备', done: false },
    { id: 4, name: '有机纯牛奶', amount: '3 盒', group: '食品饮料', note: '周末补货', done: false },
  ];
  const drawIcons = () => { if (window.lucide) window.lucide.createIcons({ attrs: { 'stroke-width': 1.65 } }); };
  function art(type) {
    if (type.startsWith('milk')) return `<div class="milk${type.includes('blue') ? ' blue' : ''}"><div class="band">ORGANIC<b>milk</b><small>PURE & SIMPLE</small></div></div>`;
    if (type === 'bottle') return '<div class="bottle"><span>C</span></div>';
    return `<div class="${type}"></div>`;
  }
  function createPhone(phone) {
    const state = { route: phone.dataset.start, category: '全部', query: '', shopping: structuredClone(initialShopping), counts: Object.fromEntries(products.map(p => [p.id, p.count])), added: [], sortAscending: true, currentProduct: null };
    phone.innerHTML = `<div class="statusbar"><span>9:41</span><span class="island" aria-hidden="true"></span><span class="system-icons">${icon('signal')}${icon('wifi')}${icon('battery-full')}</span></div><div class="screen"></div><nav class="dock" aria-label="主要导航"></nav><div class="sheet-scrim"></div><section class="sheet" aria-label="物品操作" aria-modal="true" role="dialog" inert><div class="sheet-handle" aria-label="向下拖动关闭"></div><div class="sheet-content"></div></section><div class="toast" role="status" aria-live="polite"></div>`;
    const screen = phone.querySelector('.screen');
    const dock = phone.querySelector('.dock');
    const sheet = phone.querySelector('.sheet');
    const scrim = phone.querySelector('.sheet-scrim');
    const sheetContent = phone.querySelector('.sheet-content');
    const toastBox = phone.querySelector('.toast');
    let toastTimer, undo, previousFocus;
    toastBox.inert = true;
    toastBox.setAttribute('aria-hidden', 'true');
    const header = `<div class="topline"><button class="home-name" data-action="household">${icon('house')}我的小家${icon('chevron-down').replace('<i ', '<i class="chevron" ')}</button><button class="avatar" aria-label="打开我的" data-route="profile">丁</button></div>`;
    function nav() {
      const routes = [['today', 'house', '今日'], ['inventory', 'layout-grid', '物品'], ['shopping', 'shopping-bag', '采买'], ['profile', 'circle-user-round', '我的']];
      dock.innerHTML = routes.map(([route, symbol, name]) => `<button data-route="${route}" class="${state.route === route ? 'active' : ''}"${state.route === route ? ' aria-current="page"' : ''}>${icon(symbol)}<span>${name}</span></button>`).join('');
    }
    function row(p) { return `<button class="item-row" data-product="${p.id}" aria-label="查看${p.name}"><span class="item-thumb">${art(p.art)}</span><span class="item-copy"><strong>${p.name}</strong><small>${p.location} · ${state.counts[p.id]} ${p.unit}</small></span><span class="item-trailing">${p.expiry}<small>优先安排使用</small></span></button>`; }
    function today() {
      screen.innerHTML = `${header}<div class="greeting"><p class="date">11 月 9 日，星期一</p><h2>日常，有序。</h2><p class="subtitle">家里的小事，都在这里。</p></div><section class="hero"><div class="kicker">${icon('sprout')}今天，先照顾这些</div><h3>别让好东西，<br>被时间忘记。</h3><p>2 件物品临期，记得先用它们。</p><button class="hero-button" data-action="expiring">看看是哪几件 ${icon('arrow-up-right')}</button><div class="hero-art" aria-hidden="true"><span class="leaf"></span>${art('milk')}${art('bottle')}</div></section><div class="quick-actions"><button class="quick-action" data-action="add">${icon('scan-line')}记录新物品</button><button class="quick-action" data-route="shopping">${icon('list-checks')}采买清单</button></div><div class="section-header"><h3>最近需要关注</h3><button class="text-button" data-action="expiring">查看全部 ${icon('chevron-right')}</button></div>${row(products[0])}${row(products[1])}<button class="assistant-inline" data-action="assistant">${icon('sparkles')}家里有什么，可以问问我 ${icon('arrow-up-right')}</button>`;
    }
    function inventory() {
      screen.innerHTML = `${header}<div class="title-row"><h2>家里的物品</h2><button class="round-button" aria-label="添加物品" data-action="add">${icon('plus')}</button></div><p class="collection-count"><b>48</b> 种物品，安放在 <b>6</b> 个位置</p><label class="search">${icon('search')}<input aria-label="搜索物品或位置" placeholder="找找家里有什么" type="search"></label><div class="category-tabs" role="group" aria-label="物品分类">${['全部','食品饮料','健康护理','家居日用'].map(c => `<button class="${state.category === c ? 'selected' : ''}" aria-pressed="${state.category === c}" data-category="${c}">${c}</button>`).join('')}</div><div class="inventory-meta"><span class="result-count">全部物品</span><button data-action="sort">按最近添加 ${icon('arrow-down-wide-narrow')}</button></div><div class="product-grid"></div>`;
      const input = screen.querySelector('input'); input.value = state.query;
      input.addEventListener('input', () => { state.query = input.value; grid(); }); grid();
    }
    function grid() {
      let rows = products.filter(p => (state.category === '全部' || p.group === state.category || (state.category === '临期物品' && ['milk','vitamin'].includes(p.id))) && `${p.name}${p.location}`.includes(state.query));
      if (!state.sortAscending) rows.reverse();
      screen.querySelector('.result-count').textContent = state.query ? `找到 ${rows.length} 件物品` : state.category === '全部' ? '全部物品' : state.category;
      screen.querySelector('.product-grid').innerHTML = rows.length ? rows.map((p) => `<button class="product-card" data-product="${p.id}"><div class="product-art">${['milk','vitamin'].includes(p.id) ? `<span class="product-tag">${p.id === 'milk' ? '3 天后到期' : '14 天后到期'}</span>` : ''}<span class="art-shadow"></span>${art(p.art)}</div><strong>${p.name}</strong><span class="product-meta"><span>${state.counts[p.id]} ${p.unit}</span><span>${p.category}</span></span><span class="product-location">${icon('map-pin')}${p.location}</span></button>`).join('') : '<p class="empty">没有找到匹配的物品</p>';
      drawIcons();
    }
    function shopping() {
      const remaining = state.shopping.filter(item => !item.done).length;
      screen.innerHTML = `${header}<div class="title-row"><h2>下次，带回家。</h2><button class="round-button" aria-label="添加采买项目" data-action="shopping-add">${icon('plus')}</button></div><p class="subtitle">记下来，出门就不会忘。</p><div class="shopping-banner"><div><strong>${remaining ? `还有 ${remaining} 件，等你带回家` : '这一趟，买齐了'}</strong><p>我的小家 · 日常补给</p></div><span class="bag-symbol">${icon('shopping-bag')}</span></div>${['家居日用','食品饮料'].map(group => { const rows = state.shopping.filter(item => item.group === group); return `<div class="list-section"><span>${group}</span><span>${rows.filter(i => !i.done).length} 件待买</span></div>${rows.map(item => `<div class="shopping-item ${item.done ? 'done' : ''}"><button class="check ${item.done ? 'checked' : ''}" data-check="${item.id}" aria-label="${item.done ? '取消购买' : '标记已买'}${escapeHTML(item.name)}" aria-pressed="${item.done}"><span class="circle">${item.done ? icon('check') : ''}</span></button><span class="item-copy"><strong>${escapeHTML(item.name)}</strong><small class="${item.note.includes('库存') ? 'source-note' : ''}">${item.note}</small></span><span class="quantity">${item.amount}</span></div>`).join('')}`; }).join('')}<button class="add-list" data-action="shopping-add">${icon('plus')}再记一件</button><p class="shopping-tip">${icon('circle-check')}买到后轻点圆圈，可继续为它记录入库。</p>`;
    }
    function profile() {
      screen.innerHTML = `${header}<div class="greeting"><p class="date">YOUR OWN LITTLE SPACE</p><h2>我的日常。</h2><p class="subtitle">照顾好物品，也照顾好自己。</p></div><section class="hero"><div class="kicker">${icon('house')}我的小家</div><h3>生活的秩序，<br>按你的习惯。</h3><p>48 种物品 · 6 个位置</p></section><div class="settings-list">${[['palette','外观与显示'],['bell','提醒与效期'],['users-round','家庭与共享'],['sparkles','智能助手'],['shield-check','数据与隐私']].map(([symbol,name]) => `<button data-setting="${name}">${icon(symbol)}${name}${icon('chevron-right')}</button>`).join('')}</div><p class="demo-note">MomoBox · 概念预览 V1</p>`;
    }
    function render() { ({ today, inventory, shopping, profile }[state.route])(); nav(); drawIcons(); }
    function route(name) { state.route = name; render(); screen.scrollTop = 0; }
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');
    let y = 840, velocity = 0, target = 840, animation = 0, lastTime = 0;
    function paint() { sheet.style.transform = `translateY(${y}px)`; }
    function frame(now) {
      const dt = Math.min((now - lastTime) / 1000 || 1/60, .032); lastTime = now;
      velocity += ((target - y) * 380 - velocity * 39) * dt;
      y += velocity * dt; paint();
      if (Math.abs(y - target) < .25 && Math.abs(velocity) < 2) { y = target; velocity = 0; paint(); animation = 0; if (target !== 0) sheet.inert = true; return; }
      animation = requestAnimationFrame(frame);
    }
    function spring(next, releaseVelocity) {
      target = next;
      if (releaseVelocity !== undefined) velocity = releaseVelocity;
      if (reduced.matches) { cancelAnimationFrame(animation); animation = 0; y = next; paint(); if (next !== 0) sheet.inert = true; return; }
      if (!animation) { lastTime = performance.now(); animation = requestAnimationFrame(frame); }
    }
    function openSheet(title, body) {
      previousFocus = document.activeElement;
      sheetContent.innerHTML = `<div class="sheet-title"><h3>${title}</h3><button class="sheet-close" data-action="close" aria-label="关闭弹层">${icon('x')}</button></div>${body}`;
      sheet.inert = false; scrim.classList.add('open'); spring(0); drawIcons();
      sheet.querySelector('.sheet-close').focus({preventScroll:true});
    }
    function closeSheet() { scrim.classList.remove('open'); spring(840); if (previousFocus?.isConnected) previousFocus.focus({preventScroll:true}); }
    function toast(message, callback) {
      clearTimeout(toastTimer); undo = callback;
      toastBox.innerHTML = `<span>${message}</span>${callback ? '<button data-action="undo">撤销</button>' : ''}`;
      toastBox.inert = false; toastBox.removeAttribute('aria-hidden');
      toastBox.classList.add('visible'); toastTimer = setTimeout(() => { toastBox.classList.remove('visible'); toastBox.inert = true; toastBox.setAttribute('aria-hidden', 'true'); undo = null; }, 4200);
    }
    function detail(id) {
      const p = products.find(item => item.id === id); state.currentProduct = id;
      openSheet(p.name, `<div class="detail-art">${art(p.art)}</div><p class="detail-subtitle">${p.location}</p><div class="detail-facts"><div class="detail-fact"><small>家里还有</small><strong>${state.counts[id]}<em>${p.unit}</em></strong></div><div class="detail-fact"><small>最早到期</small><strong>${id === 'milk' ? '11.12' : id === 'vitamin' ? '11.23' : '—'}</strong></div><div class="detail-fact"><small>存放位置</small><strong style="font-size:13px">${p.location.split(' · ')[1]}</strong></div></div><button class="primary-button" data-action="consume" ${state.counts[id] ? '' : 'disabled'}>${icon('minus')}用掉 1 ${p.unit}</button><button class="secondary-button" data-action="to-shopping">加入下次采买</button><p class="demo-note">演示数据 · 操作仅影响当前预览</p>`);
    }
    function addForm(shoppingOnly = false) {
      openSheet(shoppingOnly ? '下次想买什么？' : '记录一件新物品', `<form class="add-form" data-kind="${shoppingOnly ? 'shopping' : 'item'}"><label>物品名称</label><input name="name" aria-label="物品名称" placeholder="例如：厨房纸巾" maxlength="30" required><label>数量</label><input name="quantity" aria-label="数量" type="number" min="1" max="999" step="1" value="1" required><button class="primary-button form-primary" type="submit">${shoppingOnly ? '加入采买清单' : '记录到我的小家'}</button><p class="demo-note">这是视觉与交互预览，演示记录不会保存到真实库存。</p></form>`);
    }
    function act(action) {
      if (action === 'close') closeSheet();
      else if (action === 'add') addForm();
      else if (action === 'shopping-add') addForm(true);
      else if (action === 'household') openSheet('我的小家', '<p class="subtitle">此处集中管理家庭、存放位置与共享成员。</p><div class="settings-list"><button data-action="close">当前家庭：我的小家</button></div><p class="demo-note">概念预览，未连接真实家庭服务。</p>');
      else if (action === 'assistant') openSheet('家里的小助手', `<p class="subtitle">想找一件物品，或是看看需要补充什么？</p><div class="settings-list"><button data-action="expiring">${icon('clock-3')}哪些物品需要先用？${icon('arrow-up-right')}</button><button data-action="shopping-route">${icon('shopping-bag')}家里有什么需要补充？${icon('arrow-up-right')}</button></div><p class="demo-note">此处展示助手入口与建议样式，未调用模型服务。</p>`);
      else if (action === 'expiring') { closeSheet(); state.category = '临期物品'; state.query = ''; route('inventory'); }
      else if (action === 'shopping-route') { closeSheet(); route('shopping'); }
      else if (action === 'sort') { state.sortAscending = !state.sortAscending; grid(); screen.querySelector('[data-action="sort"]').innerHTML = `${state.sortAscending ? '按最近添加' : '按添加时间'} ${icon('arrow-down-wide-narrow')}`; drawIcons(); }
      else if (action === 'consume') { const id = state.currentProduct; if (!state.counts[id]) return; state.counts[id]--; closeSheet(); render(); toast('已记录使用 1 件', () => { state.counts[id]++; render(); }); }
      else if (action === 'to-shopping') { const p = products.find(p => p.id === state.currentProduct); state.shopping.push({id:Date.now(),name:p.name,amount:`1 ${p.unit}`,group:p.group === '家居日用' ? '家居日用' : '食品饮料',note:'从家里的物品添加',done:false}); closeSheet(); toast('已加入采买清单'); }
      else if (action === 'undo' && undo) { undo(); undo = null; toastBox.classList.remove('visible'); toastBox.inert = true; toastBox.setAttribute('aria-hidden', 'true'); }
    }
    phone.addEventListener('click', event => {
      const button = event.target.closest('button'); if (!button) return;
      if (button.dataset.route) { state.category = '全部'; state.query = ''; route(button.dataset.route); }
      else if (button.dataset.product) detail(button.dataset.product);
      else if (button.dataset.category) { state.category = button.dataset.category; inventory(); drawIcons(); }
      else if (button.dataset.check) { const item = state.shopping.find(i => String(i.id) === button.dataset.check); item.done = !item.done; shopping(); drawIcons(); if(item.done) toast(`已买到${escapeHTML(item.name)}`, () => { item.done = false; shopping(); drawIcons(); }); }
      else if (button.dataset.action) act(button.dataset.action);
      else if (button.dataset.setting) { if (button.dataset.setting === '外观与显示') document.getElementById('theme-toggle').click(); else openSheet(button.dataset.setting, '<p class="subtitle">在这里管理你的使用偏好。</p><p class="demo-note">本轮展示导航层级；具体设置将在后续方案中展开。</p>'); }
    });
    phone.addEventListener('submit', event => {
      const form = event.target.closest('.add-form'); if (!form) return; event.preventDefault();
      const data = new FormData(form), name = String(data.get('name')).trim(), count = Number(data.get('quantity'));
      if (!name || !Number.isInteger(count) || count < 1 || count > 999) return;
      if (form.dataset.kind === 'shopping') { state.shopping.push({id:Date.now(),name,amount:`${count} 件`,group:'家居日用',note:'手动添加',done:false}); closeSheet(); route('shopping'); toast('已记入采买清单'); }
      else { closeSheet(); toast(`演示：已记录${escapeHTML(name)} ${count} 件`); }
    });
    scrim.addEventListener('click', closeSheet);
    phone.addEventListener('keydown', event => {
      if (event.key === 'Escape' && scrim.classList.contains('open')) closeSheet();
      if (event.key === 'Tab' && scrim.classList.contains('open')) {
        const items = [...sheet.querySelectorAll('button:not(:disabled),input')];
        if (event.shiftKey && document.activeElement === items[0]) { event.preventDefault(); items.at(-1).focus(); }
        else if (!event.shiftKey && document.activeElement === items.at(-1)) { event.preventDefault(); items[0].focus(); }
      }
    });
    const handle = phone.querySelector('.sheet-handle'); let drag;
    handle.addEventListener('pointerdown', event => { cancelAnimationFrame(animation); animation = 0; handle.setPointerCapture(event.pointerId); drag = { start: event.clientY, y, samples: [{ y:event.clientY, t:performance.now() }] }; });
    handle.addEventListener('pointermove', event => { if(!drag) return; const raw = drag.y + event.clientY - drag.start; y = raw < 0 ? (raw * 480 * .55) / (480 + .55 * Math.abs(raw)) : raw; paint(); drag.samples.push({y:event.clientY,t:performance.now()}); drag.samples = drag.samples.filter(p => performance.now() - p.t < 100); });
    const release = event => { if (!drag) return; const first = drag.samples[0], now = performance.now(); const v = first ? (event.clientY - first.y) / Math.max((now - first.t) / 1000, .016) : 0; const projected = y + (v / 1000) * .99 / (1 - .99); drag = null; if (projected > 100 || (y > 70 && v >= 0)) { scrim.classList.remove('open'); spring(840, v); if (previousFocus?.isConnected) previousFocus.focus({preventScroll:true}); } else spring(0,v); };
    handle.addEventListener('pointerup', release); handle.addEventListener('pointercancel', () => { drag = null; spring(scrim.classList.contains('open') ? 0 : 840, 0); });
    render();
  }
  function escapeHTML(value) { return value.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
  document.querySelectorAll('.phone').forEach(createPhone);
  document.querySelector('.device-column').classList.add('selected');
  document.querySelectorAll('[data-preview]').forEach(button => button.addEventListener('click', () => {
    document.querySelectorAll('[data-preview]').forEach(b => b.classList.toggle('selected', b === button));
    document.querySelectorAll('.device-column').forEach((col,i) => col.classList.toggle('selected', i === Number(button.dataset.preview)));
  }));
  document.getElementById('theme-toggle').addEventListener('click', () => { const dark = document.body.classList.toggle('dark'); document.getElementById('theme-toggle').innerHTML = icon(dark ? 'sun' : 'moon'); drawIcons(); });
  drawIcons();
})();
