# 素のPostgres 17 + pgTAP + pg_cron。Supabaseなしで、全マイグレーションとpgTAPを通すための検証用イメージ
# （AWS移行の段階1、docs/AWS移行設計案.md）。本番では使わない。
FROM postgres:17
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-17-pgtap postgresql-17-cron libtap-parser-sourcehandler-pgtap-perl \
 && rm -rf /var/lib/apt/lists/*
