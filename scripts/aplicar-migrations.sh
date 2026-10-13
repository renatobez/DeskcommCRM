#!/usr/bin/env bash
# scripts/aplicar-migrations.sh
#
# Aplica no Postgres/Supabase, em ordem, só as migrations de supabase/migrations/
# que ainda NÃO constam no livro-razão `public.migrations_aplicadas`.
#
# Por que livro-razão e não "a última versão aplicada": as migrations deste repo
# nem sempre entram em ordem de número (ex.: 0645 tem timestamp anterior à 0641).
# Rastrear cada versão individualmente garante que nenhuma fique para trás.
#
# Uso:
#   SUPABASE_DB_URL='postgresql://...' scripts/aplicar-migrations.sh [opções]
#
# Opções:
#   --dry-run              só lista o que está pendente (não altera nada)
#   --bootstrap            1ª vez num banco que já tem migrations aplicadas à mão:
#                          marca TODAS como aplicadas, sem executar (use com --exceto)
#   --exceto V1,V2         com --bootstrap: versões que NÃO devem ser marcadas
#                          (as que você sabe que estão pendentes)
#   --permitir-destrutivas deixa passar migrations com DROP TABLE / DROP COLUMN /
#                          TRUNCATE no nível superior (por padrão o script para)
#
# Variáveis:
#   SUPABASE_DB_URL   obrigatória. Use a conexão DIRETA (porta 5432) ou o
#                     "Session pooler" (porta 5432). NÃO use o Transaction pooler (6543).
#   MIGRATIONS_DIR    padrão: supabase/migrations
#
# Código de saída: 0 = ok / nada pendente; 1 = erro (o deploy deve falhar).

set -euo pipefail

DIR="${MIGRATIONS_DIR:-supabase/migrations}"
DRY=0; BOOT=0; EXCETO=""; DESTRUTIVAS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --bootstrap) BOOT=1 ;;
    --exceto) EXCETO="${2:-}"; shift ;;
    --permitir-destrutivas) DESTRUTIVAS=1 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "opção desconhecida: $1" >&2; exit 1 ;;
  esac
  shift
done

: "${SUPABASE_DB_URL:?defina SUPABASE_DB_URL}"
[[ -d "$DIR" ]] || { echo "pasta não encontrada: $DIR" >&2; exit 1; }
command -v psql >/dev/null || { echo "psql não instalado" >&2; exit 1; }

export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
PSQL=(psql "$SUPABASE_DB_URL" -X -q -v ON_ERROR_STOP=1)

# Livro-razão (idempotente).
"${PSQL[@]}" <<'SQL'
create table if not exists public.migrations_aplicadas (
  versao      text primary key,
  nome        text not null,
  checksum    text not null,
  aplicada_em timestamptz not null default now(),
  origem      text not null default 'script'
);
alter table public.migrations_aplicadas enable row level security;
SQL

versao_de() { basename "$1" | cut -d_ -f1; }

# Versões já registradas.
mapfile -t APLICADAS < <("${PSQL[@]}" -At -c "select versao || '|' || checksum from public.migrations_aplicadas")
declare -A SUM
for linha in "${APLICADAS[@]}"; do SUM["${linha%%|*}"]="${linha#*|}"; done

# Lock: dois deploys simultâneos não aplicam em paralelo.
LOCK_KEY=7240131
if [[ "$("${PSQL[@]}" -At -c "select pg_try_advisory_lock($LOCK_KEY)")" != "t" ]]; then
  echo "outra execução está aplicando migrations; abortando." >&2; exit 1
fi

# ── Bootstrap ────────────────────────────────────────────────────────────────
if [[ $BOOT -eq 1 ]]; then
  IFS=',' read -ra PULAR <<< "$EXCETO"
  n=0
  for f in $(ls "$DIR"/*.sql | sort); do
    v="$(versao_de "$f")"
    [[ -n "${SUM[$v]:-}" ]] && continue
    pular=0; for p in "${PULAR[@]:-}"; do [[ -n "$p" && "$v" == "$p"* ]] && pular=1; done
    [[ $pular -eq 1 ]] && { echo "  (pendente de propósito) $(basename "$f")"; continue; }
    sum="$(sha256sum "$f" | cut -d' ' -f1)"
    if [[ $DRY -eq 0 ]]; then
      "${PSQL[@]}" -c "insert into public.migrations_aplicadas(versao,nome,checksum,origem)
                       values ('$v','$(basename "$f")','$sum','bootstrap') on conflict do nothing"
    fi
    n=$((n+1))
  done
  echo "bootstrap: $n migrations marcadas como já aplicadas."
  exit 0
fi

# ── Aplicação ────────────────────────────────────────────────────────────────
pendentes=(); alteradas=()
for f in $(ls "$DIR"/*.sql | sort); do
  v="$(versao_de "$f")"
  sum="$(sha256sum "$f" | cut -d' ' -f1)"
  if [[ -z "${SUM[$v]:-}" ]]; then
    pendentes+=("$f")
  elif [[ "${SUM[$v]}" != "$sum" ]]; then
    alteradas+=("$(basename "$f")")
  fi
done

if [[ ${#alteradas[@]} -gt 0 ]]; then
  echo "AVISO: migrations já aplicadas que mudaram no repositório (NÃO serão reaplicadas):"
  printf '  - %s\n' "${alteradas[@]}"
fi

if [[ ${#pendentes[@]} -eq 0 ]]; then echo "nada pendente."; exit 0; fi

echo "pendentes (${#pendentes[@]}):"
printf '  - %s\n' "${pendentes[@]##*/}"
[[ $DRY -eq 1 ]] && exit 0

# Guarda contra comandos destrutivos no nível superior (fora de $$...$$ e comentários).
destrutiva() {
  awk '
    { l=$0; sub(/--.*$/,"",l) }
    !dentro && tolower(l) ~ /^[ \t]*(drop[ \t]+table|truncate)([ \t]|;)/ { print FILENAME": "l; achou=1 }
    !dentro && tolower(l) ~ /^[ \t]*alter[ \t]+table.*drop[ \t]+column|^[ \t]*drop[ \t]+column/ { print FILENAME": "l; achou=1 }
    { n=gsub(/\$[A-Za-z_]*\$/,"&",l); if (n%2==1) dentro=!dentro }
    END { exit achou?0:1 }
  ' "$1"
}

if [[ $DESTRUTIVAS -eq 0 ]]; then
  bloqueio=0
  for f in "${pendentes[@]}"; do
    if destrutiva "$f"; then bloqueio=1; fi
  done
  if [[ $bloqueio -eq 1 ]]; then
    echo "PARADO: há comandos destrutivos acima. Revise e rode de novo com --permitir-destrutivas." >&2
    exit 1
  fi
fi

for f in "${pendentes[@]}"; do
  v="$(versao_de "$f")"; nome="$(basename "$f")"
  sum="$(sha256sum "$f" | cut -d' ' -f1)"
  echo "→ aplicando $nome"
  # -1: tudo em UMA transação (migration + registro). Se falhar, nada é gravado.
  if ! "${PSQL[@]}" -1 -f "$f" \
        -c "insert into public.migrations_aplicadas(versao,nome,checksum) values ('$v','$nome','$sum')" \
        -c "notify pgrst, 'reload schema'"; then
    echo "FALHOU em $nome (revertida). Migrations seguintes NÃO foram aplicadas." >&2
    exit 1
  fi
done
echo "ok: ${#pendentes[@]} migration(s) aplicada(s)."
