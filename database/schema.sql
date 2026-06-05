-- Filara 3D Tisk — databázové schema
-- Spustit v Supabase: SQL Editor → New query → vložit → Run

-- ── KATEGORIE ────────────────────────────────────────────
CREATE TABLE categories (
  id         SERIAL PRIMARY KEY,
  name       TEXT NOT NULL,
  slug       TEXT NOT NULL UNIQUE,
  sort_order INT DEFAULT 0
);

INSERT INTO categories (name, slug, sort_order) VALUES
  ('Zvířátka', 'zviratka', 1),
  ('Vázy', 'vazy', 2),
  ('Dekorace', 'dekorace', 3),
  ('Stojany', 'stojany', 4),
  ('Ostatní', 'ostatni', 5);

-- ── PRODUKTY ─────────────────────────────────────────────
CREATE TABLE products (
  id               SERIAL PRIMARY KEY,
  name             TEXT NOT NULL,
  slug             TEXT NOT NULL UNIQUE,
  description      TEXT,
  price            NUMERIC(10,2) NOT NULL,
  category_id      INT REFERENCES categories(id),
  material         TEXT DEFAULT 'PLA',
  print_time_hours NUMERIC(5,2),
  weight_grams     NUMERIC(8,2),
  images           TEXT[] DEFAULT '{}',    -- pole URL fotek
  in_stock         BOOLEAN DEFAULT FALSE,
  stock_quantity   INT DEFAULT 0,
  active           BOOLEAN DEFAULT TRUE,
  featured         BOOLEAN DEFAULT FALSE,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

-- ── UŽIVATELÉ (rozšíření Supabase Auth) ──────────────────
CREATE TABLE profiles (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name  TEXT,
  phone      TEXT,
  is_admin   BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Automaticky vytvoř profil při registraci
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO profiles (id, full_name)
  VALUES (NEW.id, NEW.raw_user_meta_data->>'full_name');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ── ADRESY ───────────────────────────────────────────────
CREATE TABLE addresses (
  id          SERIAL PRIMARY KEY,
  user_id     UUID REFERENCES profiles(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  street      TEXT NOT NULL,
  city        TEXT NOT NULL,
  zip         TEXT NOT NULL,
  country     TEXT DEFAULT 'CZ',
  is_default  BOOLEAN DEFAULT FALSE
);

-- ── OBJEDNÁVKY ───────────────────────────────────────────
CREATE TABLE orders (
  id              SERIAL PRIMARY KEY,
  order_number    TEXT NOT NULL UNIQUE,  -- napr. FIL-2026-0001
  user_id         UUID REFERENCES profiles(id),  -- NULL = nezaregistrovaný
  email           TEXT NOT NULL,
  name            TEXT NOT NULL,
  phone           TEXT,
  -- Doručovací adresa (denormalizovaná pro historii)
  shipping_street TEXT NOT NULL,
  shipping_city   TEXT NOT NULL,
  shipping_zip    TEXT NOT NULL,
  shipping_country TEXT DEFAULT 'CZ',
  -- Financie
  subtotal        NUMERIC(10,2) NOT NULL,
  shipping_cost   NUMERIC(10,2) DEFAULT 0,
  total           NUMERIC(10,2) NOT NULL,
  -- Stav
  status          TEXT DEFAULT 'new'
                  CHECK (status IN ('new','confirmed','printing','shipped','delivered','cancelled')),
  payment_status  TEXT DEFAULT 'pending'
                  CHECK (payment_status IN ('pending','paid','failed','refunded')),
  payment_id      TEXT,          -- ComGate transaction ID
  -- Poznámky
  customer_note   TEXT,
  admin_note      TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ── POLOŽKY OBJEDNÁVKY ───────────────────────────────────
CREATE TABLE order_items (
  id             SERIAL PRIMARY KEY,
  order_id       INT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id     INT REFERENCES products(id),
  product_name   TEXT NOT NULL,   -- denormalizováno
  product_image  TEXT,
  quantity       INT NOT NULL DEFAULT 1,
  unit_price     NUMERIC(10,2) NOT NULL,
  material       TEXT,
  color          TEXT,
  note           TEXT
);

-- ── AUTO ORDER NUMBER ────────────────────────────────────
CREATE OR REPLACE FUNCTION generate_order_number()
RETURNS TRIGGER AS $$
DECLARE
  year_str TEXT := TO_CHAR(NOW(), 'YYYY');
  count_today INT;
BEGIN
  SELECT COUNT(*) + 1 INTO count_today
  FROM orders
  WHERE EXTRACT(YEAR FROM created_at) = EXTRACT(YEAR FROM NOW());

  NEW.order_number := 'FIL-' || year_str || '-' || LPAD(count_today::TEXT, 4, '0');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_order_number
  BEFORE INSERT ON orders
  FOR EACH ROW EXECUTE FUNCTION generate_order_number();

-- ── AUTO UPDATED_AT ──────────────────────────────────────
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER orders_updated_at
  BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── ROW LEVEL SECURITY ───────────────────────────────────

-- Produkty: čtou všichni, píší jen admini
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
CREATE POLICY "produkty_public_read" ON products FOR SELECT USING (active = true);
CREATE POLICY "produkty_admin_all"   ON products FOR ALL
  USING ((SELECT is_admin FROM profiles WHERE id = auth.uid()));

-- Kategorie: veřejné čtení
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
CREATE POLICY "kategorie_public_read" ON categories FOR SELECT USING (true);
CREATE POLICY "kategorie_admin_all"   ON categories FOR ALL
  USING ((SELECT is_admin FROM profiles WHERE id = auth.uid()));

-- Profily: každý vidí svůj
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "profil_own" ON profiles FOR ALL USING (id = auth.uid());
CREATE POLICY "profil_admin_read" ON profiles FOR SELECT
  USING ((SELECT is_admin FROM profiles WHERE id = auth.uid()));

-- Objednávky: zákazník vidí své, admin vše
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "objednavky_own" ON orders FOR SELECT
  USING (user_id = auth.uid() OR email = auth.email());
CREATE POLICY "objednavky_insert" ON orders FOR INSERT WITH CHECK (true);
CREATE POLICY "objednavky_admin" ON orders FOR ALL
  USING ((SELECT is_admin FROM profiles WHERE id = auth.uid()));

-- Položky objednávek
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "polozky_via_order" ON order_items FOR SELECT
  USING (order_id IN (SELECT id FROM orders WHERE user_id = auth.uid()));
CREATE POLICY "polozky_insert" ON order_items FOR INSERT WITH CHECK (true);
CREATE POLICY "polozky_admin" ON order_items FOR ALL
  USING ((SELECT is_admin FROM profiles WHERE id = auth.uid()));

-- ── NASTAV SEBE JAKO ADMINA ──────────────────────────────
-- Spustit MANUÁLNĚ po první registraci:
-- UPDATE profiles SET is_admin = true WHERE id = 'TVOJE_USER_ID';
