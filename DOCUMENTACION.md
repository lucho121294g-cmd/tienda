# LimpioYa · Tienda en línea de artículos de aseo

Aplicación sencilla en **HTML + CSS + JavaScript** (sin servidor propio) con base de datos **Supabase (PostgreSQL)**.

## 1. Diseño del sistema

```
Navegador (index.html + app.js + style.css)
        │  supabase-js (HTTPS, anon key + JWT del usuario)
        ▼
Supabase: Auth ── PostgREST/RPC ── PostgreSQL (tablas + RLS + funciones)
```

- **Cliente:** catálogo, carrito, pedidos, y panel de administración (inventario, compras, kardex).
- **Backend:** toda la lógica de negocio vive en funciones SQL (`security definer`), que se ejecutan como **una sola transacción** (si algo falla, todo se revierte).
- **Roles:** `customer` (compra y ve solo lo suyo) y `admin` (inventario, compras, todos los pedidos).

### Modelo de datos

| Tabla | Propósito |
|---|---|
| `profiles` | Rol del usuario (`customer`/`admin`) |
| `products` | Catálogo: SKU, precio, `stock`, `min_stock` |
| `customer_orders` / `customer_order_items` | Pedidos de clientes y sus líneas |
| `suppliers` | Proveedores |
| `purchase_orders` / `purchase_order_items` | Órdenes de compra y sus líneas |
| `inventory_movements` | Kardex: cada entrada/salida/ajuste de stock |

Relaciones: `customer_orders 1─N customer_order_items N─1 products`; `purchase_orders 1─N purchase_order_items N─1 products`; `suppliers 1─N purchase_orders`; `products 1─N inventory_movements`.

## 2. Funciones del sistema y sus transacciones (entradas y salidas)

### T1 · Entrada de pedido de cliente — `create_order(p_address, p_items)`
- **Entradas:** usuario autenticado, dirección (5–200 car.), lista `[{product_id, qty}]` (1–50 líneas, qty 1–100).
- **Validaciones:** sesión, dirección sanitizada, stock suficiente, producto activo, máx. 10 pedidos/hora.
- **Salidas:** `id` del pedido; pedido en estado `pendiente`; stock descontado; movimientos `salida`. Error con mensaje si falla (ej. «Stock insuficiente: …»).

### T2 · Cancelación de pedido — `cancel_order(p_order_id)`
- **Entradas:** id del pedido (dueño si está `pendiente`, o admin si no está `enviado`).
- **Salidas:** pedido `cancelado`; stock devuelto; movimientos `entrada` (origen `cancelacion`).

### T3 · Pedidos de clientes (seguimiento) — `set_order_status(p_order_id, p_status)`
- **Entradas:** id del pedido, estado `pagado` o `enviado` (solo admin).
- **Salidas:** estado actualizado. No toca inventario.

### T4 · Control de inventario — `adjust_stock(p_product, p_delta, p_reason)` + consulta de stock
- **Entradas:** producto, delta (±, ≠ 0), motivo (solo admin).
- **Salidas:** nuevo stock; movimiento `ajuste`. Un ajuste que deje stock < 0 se rechaza (CHECK).
- **Consulta:** el panel Inventario resalta productos con `stock <= min_stock`.

### T5 · Orden de compra — `create_purchase_order(p_supplier, p_items)`
- **Entradas:** proveedor, líneas `[{product_id, qty, unit_cost}]` (solo admin).
- **Salidas:** `id` de la OC en estado `emitida`. No cambia stock todavía.

### T6 · Recepción de orden de compra — `receive_purchase_order(p_po)`
- **Entradas:** id de la OC en estado `emitida` (solo admin).
- **Salidas:** OC `recibida`; stock incrementado; movimientos `entrada` (origen `orden_compra`).

## 3. Sentencias SQL e impacto en la BD

| Transacción | Sentencias principales | Impacto en la BD |
|---|---|---|
| **Catálogo** | `select * from products where active order by name` | Solo lectura (RLS: público ve activos) |
| **T1 Pedido** | `insert into customer_orders …`; por línea: `select … from products … for update`, `update products set stock = stock - :qty`, `insert into customer_order_items …`, `insert into inventory_movements (…'salida'…)`; `update customer_orders set total = :total` | +1 fila `customer_orders`; +N `customer_order_items`; N filas `products` modificadas (stock ↓); +N `inventory_movements` |
| **T2 Cancelación** | `select … from customer_orders … for update`; por línea: `update products set stock = stock + :qty`, `insert into inventory_movements (…'entrada'…)`; `update customer_orders set status='cancelado'` | 1 pedido modificado; N productos (stock ↑); +N movimientos |
| **T3 Estado** | `update customer_orders set status = :estado where id = :id and status <> 'cancelado'` | 1 fila modificada; inventario sin cambios |
| **T4 Ajuste** | `update products set stock = stock + :delta where id = :id returning stock`; `insert into inventory_movements (…'ajuste'…)` | 1 producto modificado; +1 movimiento |
| **Alta de producto** | `insert into products (sku, name, price, min_stock)` | +1 producto con stock 0 |
| **T5 Crear OC** | `insert into purchase_orders …`; por línea: `insert into purchase_order_items …` | +1 OC; +N líneas; stock sin cambios |
| **T6 Recibir OC** | `select status from purchase_orders … for update`; por línea: `update products set stock = stock + :qty`, `insert into inventory_movements (…'entrada'…)`; `update purchase_orders set status='recibida'` | 1 OC modificada; N productos (stock ↑); +N movimientos |
| **Kardex** | `select … from inventory_movements order by id desc limit 60` | Solo lectura (admin) |

**Integridad:** `for update` evita vender el mismo stock dos veces en pedidos simultáneos; los `CHECK` impiden stock negativo, cantidades ≤ 0 y estados inválidos.

## 4. Seguridad aplicada

1. **Llaves/secretos:** el navegador solo usa la *anon key* (pública por diseño) en `config.js`; la `service_role` nunca va en el código. Al ser un sitio estático no hay variables de entorno en tiempo de ejecución; si más adelante agregas un backend (Edge Functions), sus secretos van en variables de entorno de Supabase.
2. **CORS:** la API REST de Supabase acepta cualquier origen, y no se puede limitar por dominio desde el panel. Por eso la protección real es RLS + funciones con permisos. Si agregas Edge Functions, restringe `Access-Control-Allow-Origin` a tu dominio. En Auth → URL Configuration deja solo tu dominio en *Site URL* y *Redirect URLs*.
3. **Validación en backend:** las funciones y los `CHECK` validan todo (tipos, rangos, estados), no solo el formulario.
4. **Sanitización:** se eliminan `<` y `>` de textos libres antes de guardar, y el cliente nunca usa `innerHTML` (solo `textContent`).
5. **Rate limiting:** `create_order` limita a 10 pedidos/hora por usuario. Además, activa los límites de Auth en el panel de Supabase (Authentication → Rate Limits). Un límite por IP para toda la API requiere un WAF/CDN delante.
6. **RLS:** activado en todas las tablas. Los clientes solo ven sus pedidos; pedidos, compras y movimientos no tienen políticas de escritura (solo se modifican vía funciones).
7. **CSP:** meta etiqueta en `index.html` que solo permite scripts propios y de `cdn.jsdelivr.net`, y conexiones a `*.supabase.co`. Cuando la publiques, reemplaza `*.supabase.co` por tu dominio exacto del proyecto y, si puedes, configura la CSP como cabecera HTTP del hosting.

## 5. Puesta en marcha

1. Crea un proyecto en Supabase y ejecuta `schema.sql` en **SQL Editor**.
2. Copia *Project URL* y *anon key* a `config.js`.
3. Abre `index.html` con un servidor estático (por ejemplo `npx serve` o la extensión Live Server de VS Code).
4. Regístrate en la tienda y vuélvete admin en el SQL Editor:
   `update profiles set role = 'admin' where id = '<tu-uuid de auth.users>';`
5. Prueba el flujo: crear OC → recibir mercancía (stock ↑) → comprar como cliente (stock ↓) → revisar Kardex.
