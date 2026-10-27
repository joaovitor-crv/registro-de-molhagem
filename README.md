# Controle de Poeira

Acompanhamento da molhagem das estradas: cada molhagem registrada por ponto e frota, o tempo desde a última e a previsão da próxima.

Perfis: **Administrador** (cadastra pontos, frotas e usuários), **Operador** (registra molhagens) e **Consulta** (apenas acompanha).

- Site: https://jvitoradm19.github.io/registro-de-molhagem
- Banco de dados e login: Supabase, no mesmo projeto do sistema fadiga (tabelas `molh_`). Este repositório contém só a página.
- Estrutura do banco: `supabase/molhagem.sql` (rodar uma vez no SQL Editor do Supabase).
