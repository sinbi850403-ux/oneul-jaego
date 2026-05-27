-- ================================================
-- 오늘재고 (oneul-jaego) 스키마
-- Supabase 대시보드 → SQL Editor에 붙여넣고 실행
-- ================================================

-- 상품 테이블
create table if not exists products (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users not null,
  name        text not null,
  unit        text not null default '개',
  is_favorite boolean not null default false,
  created_at  timestamptz default now(),
  unique (user_id, name)
);

-- 재고 테이블 (상품별 현재 수량)
create table if not exists stock (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references auth.users not null,
  product_id uuid references products(id) on delete cascade not null,
  quantity   int not null default 0,
  updated_at timestamptz default now(),
  unique (user_id, product_id)
);

-- 입출고 이력 테이블
create table if not exists stock_log (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references auth.users not null,
  product_id uuid references products(id) on delete cascade not null,
  type       text not null check (type in ('in', 'out', 'return')),
  quantity   int not null,
  source     text not null default 'manual',
  note       text,
  created_at timestamptz default now()
);

-- 재고실사 세션 테이블
create table if not exists stocktake (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users not null,
  status      text not null default 'in_progress' check (status in ('in_progress', 'done')),
  started_at  timestamptz default now(),
  finished_at timestamptz
);

-- 재고실사 항목 테이블
create table if not exists stocktake_item (
  id           uuid primary key default gen_random_uuid(),
  stocktake_id uuid references stocktake(id) on delete cascade not null,
  product_id   uuid references products(id) on delete cascade not null,
  system_qty   int not null default 0,
  actual_qty   int,
  diff         int generated always as (coalesce(actual_qty, 0) - system_qty) stored,
  adjusted     boolean not null default false
);

-- ================================================
-- RLS 활성화
-- ================================================

alter table products      enable row level security;
alter table stock         enable row level security;
alter table stock_log     enable row level security;
alter table stocktake     enable row level security;
alter table stocktake_item enable row level security;

-- ================================================
-- RLS 정책 (본인 데이터만)
-- ================================================

create policy "own products"      on products      for all using (auth.uid() = user_id);
create policy "own stock"         on stock         for all using (auth.uid() = user_id);
create policy "own stock_log"     on stock_log     for all using (auth.uid() = user_id);
create policy "own stocktake"     on stocktake     for all using (auth.uid() = user_id);

-- stocktake_item은 stocktake를 통해 본인 것만 접근
create policy "own stocktake_item" on stocktake_item for all
  using (
    exists (
      select 1 from stocktake
      where stocktake.id = stocktake_item.stocktake_id
        and stocktake.user_id = auth.uid()
    )
  );

-- ================================================
-- 입고 처리 함수
-- ================================================
create or replace function handle_stock_in(
  p_user_id    uuid,
  p_product_id uuid,
  p_quantity   int,
  p_note       text default null
) returns void language plpgsql security definer as $$
begin
  -- 재고 증가 (없으면 insert)
  insert into stock (user_id, product_id, quantity)
    values (p_user_id, p_product_id, p_quantity)
    on conflict (user_id, product_id)
    do update set quantity = stock.quantity + p_quantity, updated_at = now();

  -- 이력 기록
  insert into stock_log (user_id, product_id, type, quantity, note)
    values (p_user_id, p_product_id, 'in', p_quantity, p_note);
end;
$$;

-- ================================================
-- 출고 처리 함수
-- ================================================
create or replace function handle_stock_out(
  p_user_id    uuid,
  p_product_id uuid,
  p_quantity   int,
  p_note       text default null
) returns void language plpgsql security definer as $$
begin
  -- 재고 감소
  update stock
    set quantity = quantity - p_quantity, updated_at = now()
    where user_id = p_user_id and product_id = p_product_id;

  -- 이력 기록
  insert into stock_log (user_id, product_id, type, quantity, note)
    values (p_user_id, p_product_id, 'out', p_quantity, p_note);
end;
$$;

-- ================================================
-- 반품 처리 함수 (재고 복구)
-- ================================================
create or replace function handle_stock_return(
  p_user_id    uuid,
  p_product_id uuid,
  p_quantity   int,
  p_note       text default null
) returns void language plpgsql security definer as $$
begin
  -- 재고 증가
  update stock
    set quantity = quantity + p_quantity, updated_at = now()
    where user_id = p_user_id and product_id = p_product_id;

  -- 이력 기록
  insert into stock_log (user_id, product_id, type, quantity, note)
    values (p_user_id, p_product_id, 'return', p_quantity, p_note);
end;
$$;

-- ================================================
-- 안전재고 컬럼 추가 (products)
-- ================================================
alter table products add column if not exists min_quantity int not null default 0;

-- ================================================
-- 거래처 테이블
-- ================================================
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
create policy "own suppliers" on suppliers for all using (auth.uid() = user_id);

-- ================================================
-- 발주 테이블
-- ================================================
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
create policy "own orders" on orders for all using (auth.uid() = user_id);

-- ================================================
-- 발주 항목 테이블
-- ================================================
create table if not exists order_items (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid references orders(id) on delete cascade not null,
  product_id uuid references products(id) on delete cascade not null,
  quantity   int not null default 1
);

alter table order_items enable row level security;

-- order_items는 orders를 통해 본인 것만 접근
create policy "own order_items" on order_items for all
  using (
    exists (
      select 1 from orders
      where orders.id = order_items.order_id
        and orders.user_id = auth.uid()
    )
  );

-- ================================================
-- 재고실사 오차 조정 함수
-- ================================================
create or replace function handle_stocktake_adjust(
  p_item_id    uuid,
  p_user_id    uuid,
  p_product_id uuid,
  p_actual_qty int
) returns void language plpgsql security definer as $$
declare
  v_system_qty int;
  v_diff       int;
  v_type       text;
begin
  select system_qty into v_system_qty
    from stocktake_item where id = p_item_id;

  v_diff := p_actual_qty - v_system_qty;

  if v_diff = 0 then
    update stocktake_item set adjusted = true where id = p_item_id;
    return;
  end if;

  -- 오차 방향에 따라 입고/출고 처리
  if v_diff > 0 then
    v_type := 'in';
    update stock
      set quantity = quantity + v_diff, updated_at = now()
      where user_id = p_user_id and product_id = p_product_id;
  else
    v_type := 'out';
    update stock
      set quantity = quantity + v_diff, updated_at = now()
      where user_id = p_user_id and product_id = p_product_id;
  end if;

  -- 이력 기록
  insert into stock_log (user_id, product_id, type, quantity, source, note)
    values (p_user_id, p_product_id, v_type, abs(v_diff), 'jangbu', '재고실사 조정');

  -- 조정 완료 표시
  update stocktake_item set adjusted = true where id = p_item_id;
end;
$$;
