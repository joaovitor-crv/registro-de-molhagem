# Controle de Poeira

Acompanhamento da molhagem das estradas: cada molhagem registrada por ponto e frota, o tempo desde a última e a previsão da próxima.

Perfis: **Administrador** (cadastra pontos, frotas e usuários), **Operador** (registra molhagens) e **Consulta** (apenas acompanha).

- Site: https://jvitoradm19.github.io/registro-de-molhagem
- Banco de dados e login: Supabase, no mesmo projeto do sistema fadiga (tabelas `molh_`). Este repositório contém só a página.
- Estrutura do banco: `supabase/molhagem.sql` (rodar uma vez no SQL Editor do Supabase).
- Informativo de chuva: `supabase/chuva.sql`. No painel, **Informar chuva** abre a lista de pontos; o operador marca onde choveu e confirma. Os pontos marcados ficam **dispensados por 12 horas** (aparecem em azul no painel e nos PDFs, e não contam como atrasados). Depois das 12 h o prazo de molhagem volta a contar a partir do fim da dispensa. A dispensa pode ser encerrada antes, e o informativo lançado por engano pode ser excluído no Histórico.
