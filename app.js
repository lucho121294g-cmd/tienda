'use strict';
const { SUPABASE_URL, SUPABASE_ANON_KEY } = window.APP_CONFIG;
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// ---------- utilidades (nunca se usa innerHTML: todo texto va con textContent) ----------
const $ = s => document.querySelector(s);
const money = n => new Intl.NumberFormat('es-CO', { style: 'currency', currency: 'COP', maximumFractionDigits: 0 }).format(n);
const fdate = d => new Date(d).toLocaleString('es-CO');
function h(tag, props = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k.startsWith('on')) e.addEventListener(k.slice(2), v); else e[k] = v;
  }
  kids.flat().forEach(c => e.append(c instanceof Node ? c : String(c ?? '')));
  return e;
}
const toast = (m, err) => { const t = $('#toast'); t.textContent = m; t.className = err ? 'err' : 'ok'; setTimeout(() => (t.textContent = ''), 4500); };
const run = async (fn, ok) => { try { await fn(); if (ok) toast(ok); } catch (e) { toast(e.message || 'Error inesperado', true); } };
const q = async p => { const { data, error } = await p; if (error) throw error; return data; };
const rpc = (n, a) => q(sb.rpc(n, a));
const table = (heads, rows) => h('div', { className: 'tbl-wrap' }, h('table', {},
  h('thead', {}, h('tr', {}, heads.map(x => h('th', {}, x)))),
  h('tbody', {}, rows)));

let cart = {}, products = [], user = null, isAdmin = false, current = 'store';

// ---------- sesión ----------
$('#auth').addEventListener('submit', e => { e.preventDefault(); run(async () => {
  const { error } = await sb.auth.signInWithPassword({ email: $('#email').value.trim(), password: $('#pass').value });
  if (error) throw error;
}); });
$('#signup').addEventListener('click', () => run(async () => {
  const { error } = await sb.auth.signUp({ email: $('#email').value.trim(), password: $('#pass').value });
  if (error) throw error;
}, 'Cuenta creada. Revisa tu correo si pide confirmación.'));
$('#logout').addEventListener('click', () => sb.auth.signOut());

async function setUser(u) {
  user = u; isAdmin = false;
  if (u) {
    const { data } = await sb.from('profiles').select('role').eq('id', u.id).single();
    isAdmin = data?.role === 'admin';
  }
  $('#auth').hidden = !!u; $('#session').hidden = !u; $('#who').textContent = u ? u.email : '';
  $('#nav-orders').hidden = !u;
  document.querySelectorAll('.admin-only').forEach(el => (el.hidden = !isAdmin));
  if (!u && current !== 'store') current = 'store';
  await loadProducts(); show(current);
}

// ---------- navegación ----------
document.querySelectorAll('nav button').forEach(b => b.addEventListener('click', () => show(b.dataset.view)));
const views = { store: null, orders: renderOrders, inventory: renderInventory, purchases: renderPurchases, movements: renderMovements };
function show(v) {
  current = v;
  document.querySelectorAll('.view').forEach(s => (s.hidden = s.id !== 'v-' + v));
  if (views[v]) run(() => views[v]($('#v-' + v)));
  else renderStore();
}

// ---------- tienda y carrito ----------
async function loadProducts() { products = await q(sb.from('products').select('*').eq('active', true).order('name')); renderStore(); renderCart(); }
function renderStore() {
  $('#grid').replaceChildren(...products.map(p => h('article', { className: 'card' },
    h('h3', {}, p.name), h('p', { className: 'muted' }, p.description || ''),
    h('strong', {}, money(p.price)), h('small', {}, p.stock > 0 ? `Disponibles: ${p.stock}` : 'Agotado'),
    h('button', { disabled: p.stock < 1, onclick: () => { cart[p.id] = Math.min((cart[p.id] || 0) + 1, p.stock); renderCart(); } }, 'Agregar'))));
}
function renderCart() {
  let total = 0; const ids = Object.keys(cart);
  $('#cart-items').replaceChildren(...ids.map(id => {
    const p = products.find(x => x.id == id); if (!p) return '';
    total += p.price * cart[id];
    return h('li', {}, `${p.name} × ${cart[id]} — ${money(p.price * cart[id])} `,
      h('button', { className: 'alt', onclick: () => { delete cart[id]; renderCart(); } }, '✕'));
  }));
  $('#total').textContent = money(total);
  $('#checkout').disabled = !ids.length || !user;
}
$('#checkout').addEventListener('click', () => run(async () => {
  const items = Object.entries(cart).map(([product_id, qty]) => ({ product_id: +product_id, qty }));
  const id = await rpc('create_order', { p_address: $('#address').value, p_items: items });
  cart = {}; await loadProducts(); toast(`Pedido #${id} creado`);
}));

// ---------- pedidos (cliente: los suyos; admin: todos) ----------
async function renderOrders(box) {
  const rows = await q(sb.from('customer_orders')
    .select('id,status,total,address,created_at,customer_order_items(qty,unit_price,products(name))')
    .order('created_at', { ascending: false }).limit(50));
  const act = (label, fn, alt) => h('button', { className: alt ? 'alt' : '', onclick: () => run(async () => { await fn(); show('orders'); }, 'Listo') }, label);
  box.replaceChildren(h('h2', {}, isAdmin ? 'Todos los pedidos' : 'Mis pedidos'), ...rows.map(o => h('div', { className: 'order' },
    h('strong', {}, `Pedido #${o.id} · ${o.status.toUpperCase()} · ${money(o.total)}`),
    h('small', {}, `${fdate(o.created_at)} · ${o.address}`),
    h('ul', {}, o.customer_order_items.map(i => h('li', {}, `${i.products.name} × ${i.qty} (${money(i.unit_price)})`))),
    h('div', { className: 'row' },
      (isAdmin && o.status === 'pendiente') ? act('Marcar pagado', () => rpc('set_order_status', { p_order_id: o.id, p_status: 'pagado' })) : '',
      (isAdmin && o.status === 'pagado') ? act('Marcar enviado', () => rpc('set_order_status', { p_order_id: o.id, p_status: 'enviado' })) : '',
      (['pendiente', 'pagado'].includes(o.status) && (isAdmin || o.status === 'pendiente')) ? act('Cancelar', () => rpc('cancel_order', { p_order_id: o.id }), true) : ''))));
}

// ---------- inventario (admin) ----------
async function renderInventory(box) {
  const rows = await q(sb.from('products').select('*').order('name'));
  const f = h('form', { className: 'row', onsubmit: e => { e.preventDefault(); const t = e.target; run(async () => {
      await q(sb.from('products').insert({ sku: t.sku.value.trim().toUpperCase(), name: t.pname.value.trim(), price: +t.price.value, min_stock: +t.min.value }));
      await loadProducts(); show('inventory');
    }, 'Producto creado'); } },
    h('input', { name: 'sku', placeholder: 'SKU (DET-002)', required: true, maxLength: 20 }),
    h('input', { name: 'pname', placeholder: 'Nombre', required: true, maxLength: 120 }),
    h('input', { name: 'price', type: 'number', min: 0, step: '0.01', placeholder: 'Precio', required: true }),
    h('input', { name: 'min', type: 'number', min: 0, value: 5, required: true }),
    h('button', { type: 'submit' }, 'Crear producto'));
  box.replaceChildren(h('h2', {}, 'Control de inventario'), f, table(['SKU', 'Producto', 'Precio', 'Stock', 'Mínimo', ''],
    rows.map(p => h('tr', { className: p.stock <= p.min_stock ? 'low' : '' },
      h('td', {}, p.sku), h('td', {}, p.name), h('td', {}, money(p.price)), h('td', {}, p.stock), h('td', {}, p.min_stock),
      h('td', {}, h('button', { className: 'alt', onclick: () => run(async () => {
        const d = parseInt(prompt(`Ajuste de stock para ${p.name} (ej. -3 o 10):`), 10);
        if (!d) return;
        await rpc('adjust_stock', { p_product: p.id, p_delta: d, p_reason: 'ajuste manual' }); await loadProducts(); show('inventory');
      }, 'Stock ajustado') }, 'Ajustar'))))));
}

// ---------- órdenes de compra (admin) ----------
async function renderPurchases(box) {
  const [sup, prods, pos] = await Promise.all([
    q(sb.from('suppliers').select('*').order('name')),
    q(sb.from('products').select('id,name').order('name')),
    q(sb.from('purchase_orders').select('id,status,created_at,suppliers(name),purchase_order_items(qty,unit_cost,products(name))').order('id', { ascending: false }).limit(30))]);
  const fs = h('form', { className: 'row', onsubmit: e => { e.preventDefault(); run(async () => {
      await q(sb.from('suppliers').insert({ name: e.target.sname.value.trim(), contact: e.target.contact.value.trim() })); show('purchases');
    }, 'Proveedor creado'); } },
    h('input', { name: 'sname', placeholder: 'Proveedor', required: true, minLength: 2, maxLength: 100 }),
    h('input', { name: 'contact', placeholder: 'Contacto', maxLength: 200 }), h('button', { type: 'submit' }, 'Agregar proveedor'));
  const fo = h('form', { className: 'row', onsubmit: e => { e.preventDefault(); const t = e.target; run(async () => {
      await rpc('create_purchase_order', { p_supplier: +t.sup.value, p_items: [{ product_id: +t.prod.value, qty: +t.qty.value, unit_cost: +t.cost.value }] });
      show('purchases');
    }, 'Orden de compra creada'); } },
    h('select', { name: 'sup', required: true }, sup.map(s => h('option', { value: s.id }, s.name))),
    h('select', { name: 'prod', required: true }, prods.map(p => h('option', { value: p.id }, p.name))),
    h('input', { name: 'qty', type: 'number', min: 1, placeholder: 'Cantidad', required: true }),
    h('input', { name: 'cost', type: 'number', min: 0, step: '0.01', placeholder: 'Costo unitario', required: true }),
    h('button', { type: 'submit' }, 'Crear orden de compra'));
  box.replaceChildren(h('h2', {}, 'Órdenes de compra'), fs, fo, ...pos.map(po => h('div', { className: 'order' },
    h('strong', {}, `OC #${po.id} · ${po.suppliers.name} · ${po.status.toUpperCase()}`), h('small', {}, fdate(po.created_at)),
    h('ul', {}, po.purchase_order_items.map(i => h('li', {}, `${i.products.name} × ${i.qty} a ${money(i.unit_cost)}`))),
    po.status === 'emitida' ? h('div', { className: 'row' }, h('button', { onclick: () => run(async () => {
      await rpc('receive_purchase_order', { p_po: po.id }); await loadProducts(); show('purchases');
    }, 'Mercancía recibida: stock actualizado') }, 'Recibir mercancía')) : '')));
}

// ---------- movimientos / kardex (admin) ----------
async function renderMovements(box) {
  const rows = await q(sb.from('inventory_movements').select('id,type,qty,ref_type,ref_id,note,created_at,products(name)').order('id', { ascending: false }).limit(60));
  box.replaceChildren(h('h2', {}, 'Kardex (últimos 60 movimientos)'), table(['Fecha', 'Producto', 'Tipo', 'Cant.', 'Origen'],
    rows.map(m => h('tr', {}, h('td', {}, fdate(m.created_at)), h('td', {}, m.products.name), h('td', {}, m.type), h('td', {}, m.qty),
      h('td', {}, `${m.ref_type || ''} ${m.ref_id ? '#' + m.ref_id : ''} ${m.note || ''}`)))));
}

// ---------- arranque ----------
(async () => {
  const { data: { session } } = await sb.auth.getSession();
  await setUser(session?.user ?? null);
  sb.auth.onAuthStateChange((ev, s) => { if (ev === 'SIGNED_IN' || ev === 'SIGNED_OUT') setUser(s?.user ?? null); });
})();
