-- Efetivar venda de freezer: vencimento passa a ser definido no envio (Recebíveis)
-- e a efetivação gera uma ordem de envio (logistica_entregas, tipo 'freezer').

alter table logistica_entregas
  add column if not exists visita_id uuid references freezer_visitas(id);

create unique index if not exists ux_logistica_entregas_visita
  on logistica_entregas (visita_id) where visita_id is not null;

create or replace function public.efetivar_venda_freezer(
  p_visita_id uuid, p_numero_nota text, p_forma_pagamento text, p_parcelas jsonb,
  p_desconto_tipo text default null, p_desconto_valor numeric default null, p_desconto_motivo text default null)
returns bigint
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_freezer_id uuid;
  v_data_visita date;
  v_pedido_tirado boolean;
  v_status_atual text;
  v_valor_bruto numeric;
  v_valor_desconto numeric := 0;
  v_valor_liquido numeric;
  v_desconto_tipo text := null;
  v_desconto_informado numeric := null;
  v_soma_parcelas numeric;
  v_obs text := null;
  v_codigo_cliente text;
  v_nome_cliente text;
  v_primeira_venc date;
  v_cobranca_id bigint;
  v_parcelas_norm jsonb;
  v_fz freezers%rowtype;
begin
  select freezer_id, data_visita, pedido_tirado, status_venda
    into v_freezer_id, v_data_visita, v_pedido_tirado, v_status_atual
  from freezer_visitas where id = p_visita_id;

  if v_freezer_id is null then
    raise exception 'Visita/proposta não encontrada.';
  end if;
  if not tem_acesso_freezer(v_freezer_id) then
    raise exception 'Sem acesso a este freezer.';
  end if;
  if not v_pedido_tirado then
    raise exception 'Esta visita não tem pedido — não há o que efetivar.';
  end if;
  if v_status_atual = 'efetivada' then
    raise exception 'Esta proposta já foi efetivada.';
  end if;
  if p_parcelas is null or jsonb_array_length(p_parcelas) = 0 then
    raise exception 'Informe ao menos uma parcela.';
  end if;

  select round(coalesce(sum(quantidade * valor_unitario), 0), 2) into v_valor_bruto
  from freezer_visita_itens where visita_id = p_visita_id;

  if p_desconto_tipo is not null and coalesce(p_desconto_valor, 0) <> 0 then
    if p_desconto_tipo = 'percentual' then
      if p_desconto_valor < 0 or p_desconto_valor > 100 then
        raise exception 'Desconto percentual precisa estar entre 0%% e 100%%.';
      end if;
      v_valor_desconto := round(v_valor_bruto * p_desconto_valor / 100, 2);
    elsif p_desconto_tipo = 'valor' then
      if p_desconto_valor < 0 or p_desconto_valor > v_valor_bruto then
        raise exception 'Desconto em R$ não pode ser negativo nem maior que o valor da venda.';
      end if;
      v_valor_desconto := round(p_desconto_valor, 2);
    else
      raise exception 'Tipo de desconto inválido (use percentual ou valor).';
    end if;
    v_desconto_tipo := p_desconto_tipo;
    v_desconto_informado := p_desconto_valor;
  end if;

  v_valor_liquido := v_valor_bruto - v_valor_desconto;
  if v_valor_liquido <= 0 then
    raise exception 'O valor líquido da venda precisa ser maior que zero.';
  end if;

  select coalesce(sum((elem->>'valor')::numeric), 0) into v_soma_parcelas
  from jsonb_array_elements(p_parcelas) elem;
  if abs(v_soma_parcelas - v_valor_liquido) > 0.01 then
    raise exception 'A soma das parcelas (R$ %) não bate com o valor líquido da venda (R$ %).',
      v_soma_parcelas, v_valor_liquido;
  end if;

  if v_valor_desconto > 0 then
    v_obs := 'Desconto comercial de R$ ' || replace(to_char(v_valor_desconto, 'FM999999990.00'), '.', ',')
      || case when v_desconto_tipo = 'percentual'
              then ' (' || replace(to_char(v_desconto_informado, 'FM990.00'), '.', ',') || '%)'
              else '' end
      || ' sobre valor bruto de R$ ' || replace(to_char(v_valor_bruto, 'FM999999990.00'), '.', ',')
      || coalesce(' — ' || nullif(trim(p_desconto_motivo), ''), '');
  end if;

  select * into v_fz from freezers where id = v_freezer_id;
  v_codigo_cliente := v_fz.codigo_cliente;
  v_nome_cliente := coalesce(v_fz.razao_social, v_fz.nome_fantasia, v_fz.ponto_venda);

  -- Vencimento é opcional: é definido no envio, direto no Recebíveis.
  select jsonb_agg(jsonb_build_object(
           'num', rn,
           'valor', valor,
           'valor_recebido', 0,
           'forma_pagamento', p_forma_pagamento,
           'data_vencimento', vencimento,
           'pago', false,
           'situacao', 'Pendente'
         ) order by rn)
    into v_parcelas_norm
  from (
    select row_number() over (order by nullif(elem->>'vencimento','')::date nulls last, ord) as rn,
           (elem->>'valor')::numeric as valor,
           nullif(elem->>'vencimento','') as vencimento
    from jsonb_array_elements(p_parcelas) with ordinality as t(elem, ord)
  ) ordenadas;

  select min(nullif(elem->>'vencimento','')::date) into v_primeira_venc
  from jsonb_array_elements(p_parcelas) elem;

  insert into cobrancas (codigo_cliente, nome_cliente, numero_nota, valor_total, forma_pagamento,
                          data_vencimento, status, data_venda, parcelas, origem_visita_id, origem, observacoes)
  values (coalesce(v_codigo_cliente,'—'), v_nome_cliente, nullif(trim(coalesce(p_numero_nota,'')),''),
          v_valor_liquido, p_forma_pagamento, v_primeira_venc, 'Pendente', v_data_visita, v_parcelas_norm,
          p_visita_id, 'Freezer Externo', v_obs)
  returning id into v_cobranca_id;

  update freezer_visitas set
    status_venda = 'efetivada',
    numero_nota = nullif(trim(coalesce(p_numero_nota,'')),''),
    forma_pagamento = p_forma_pagamento,
    parcelas = v_parcelas_norm,
    data_efetivacao = now(),
    efetivado_por = auth.uid(),
    desconto_tipo = v_desconto_tipo,
    desconto_informado = v_desconto_informado,
    desconto_motivo = nullif(trim(coalesce(p_desconto_motivo,'')),''),
    valor_bruto = v_valor_bruto,
    valor_desconto = v_valor_desconto,
    valor_liquido = v_valor_liquido
  where id = p_visita_id;

  -- Ordem de envio para a Logística (sem rota: a logística programa depois)
  insert into logistica_entregas (tipo, freezer_id, freezer_codigo, freezer_rede, destino_nome, destino_endereco,
                                  destino_cidade, latitude, longitude, status, visita_id, observacoes)
  values ('freezer', v_freezer_id, v_fz.codigo, v_fz.rede, v_fz.ponto_venda, v_fz.endereco,
          v_fz.cidade, v_fz.latitude, v_fz.longitude, 'pendente', p_visita_id,
          'Envio da venda efetivada em ' || to_char(now() at time zone 'America/Sao_Paulo', 'DD/MM/YYYY')
          || ' — R$ ' || replace(to_char(v_valor_liquido, 'FM999999990.00'), '.', ',')
          || coalesce(' — NF ' || nullif(trim(coalesce(p_numero_nota,'')),''), ''))
  on conflict (visita_id) where visita_id is not null do nothing;

  return v_cobranca_id;
end;
$function$;
