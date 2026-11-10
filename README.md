# Controle de Poeira

Acompanhamento da molhagem das estradas: cada molhagem registrada por ponto e frota, o tempo desde a última e a previsão da próxima.

Perfis: **Administrador** (cadastra pontos, frotas e usuários), **Operador** (registra molhagens) e **Consulta** (apenas acompanha).

- Site: https://jvitoradm19.github.io/registro-de-molhagem
- Banco de dados e login: Supabase, no mesmo projeto do sistema fadiga (tabelas `molh_`). Este repositório contém só a página.
- Estrutura do banco: `supabase/molhagem.sql` (rodar uma vez no SQL Editor do Supabase).
- Informativo de chuva: `supabase/chuva.sql`. No painel, **Informar chuva** abre a lista de pontos; o operador marca onde choveu e confirma. Os pontos marcados ficam **dispensados por 12 horas** (aparecem em azul no painel e nas imagens exportadas, e não contam como atrasados). Depois das 12 h o prazo de molhagem volta a contar a partir do fim da dispensa. A dispensa pode ser encerrada antes, e o informativo lançado por engano pode ser excluído no Histórico.
- Responsável pela informação (`supabase/responsavel.sql`, 10/11/2026): campo opcional (deixou de ser obrigatório em 10/11/2026, a pedido do usuário) ao registrar molhagem e saída de frota (quem passou a informação; o último informado fica preenchido no aparelho). Aparece no painel ("Informado por" no cartão do ponto e na frota em trajeto), na imagem do painel, no relatório e no Histórico. Na chegada do trajeto, a molhagem leva o responsável da saída.
- Exportação: **Imagem do painel (PNG)** gera os cartões do painel e **Exportar PNG** gera o relatório em tabelas, cada um numa imagem única e contínua (sem quebra de página). A mesma imagem do painel é a que o robô envia no WhatsApp (repositório `envio-whatsapp-poeira`).
