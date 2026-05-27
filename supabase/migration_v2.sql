-- ================================================
-- 오늘재고 v2 마이그레이션
-- 기존 DB에 추가 실행용 (이미 schema.sql 적용된 경우)
-- Supabase 대시보드 → SQL Editor에 붙여넣고 실행
-- ================================================

-- 1. products 테이블에 안전재고 컬럼 추가
alter table products add column if not exists min_quantity int not null default 0;

-- 2. 거래처 테이블
create table if not exists suppliers (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references auth.users not null,
  name         text not null,
  contact_name text,
  phone        text,
  email        text,
  memo         text,
  created_at   timestamptz default now(),
  unique (user_id, name)
);

alter table suppliers enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies where tablename = 'suppliers' and policyname = 'own suppliers'
  ) then
    create policy "own suppliers" on suppliers for all using (auth.uid() = user_id);
  end if;
end $$;

-- 3. 발주 테이블
create table if not exists orders (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references auth.users not null,
  supplier_id  uuid references suppliers(id) on delete set null,
  status       text not null default 'pending' check (status in ('pending', 'completed', 'cancelled')),
  note         text,
  created_at   timestamptz default now(),
  completed_at timestamptz
);

alter table orders enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies where tablename = 'orders' and policyname = 'own orders'
  ) then
    create policy "own orders" on orders for all using (auth.uid() = user_id);
  end if;
end $$;

-- 4. 발주 항목 테이블
create table if not exists order_items (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid references orders(id) on delete cascade not null,
  product_id uuid references products(id) on delete cascade not null,
  quantity   int not null default 1
);

alter table order_items enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies where tablename = 'order_items' and policyname = 'own order_items'
  ) then
    create policy "own order_items" on order_items for all
      using (
        exists (
          select 1 from orders
          where orders.id = order_items.order_id
            and orders.user_id = auth.uid()
        )
      );
  end if;
end $$;
