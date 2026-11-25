# Controle de Poeira

Acompanhamento da molhagem das estradas: cada molhagem registrada por ponto e frota, o tempo desde a última e a previsão da próxima.

Perfis: **Administrador** (cadastra pontos, frotas e usuários), **Operador** (registra molhagens) e **Consulta** (apenas acompanha).

- Site: https://jvitoradm19.github.io/registro-de-molhagem
- Banco de dados e login: Supabase, no mesmo projeto do sistema fadiga (tabelas `molh_`). Este repositório contém só a página.
- Estrutura do banco: `supabase/molhagem.sql` (rodar uma vez no SQL Editor do Supabase).
- Informativo de chuva: `supabase/chuva.sql`. No painel, **Informar chuva** abre a lista de pontos; o operador marca onde choveu e confirma. Os pontos marcados ficam **dispensados por 12 horas** (aparecem em azul no painel e nas imagens exportadas, e não contam como atrasados). Depois das 12 h o prazo de molhagem volta a contar a partir do fim da dispensa. A dispensa pode ser encerrada antes, e o informativo lançado por engano pode ser excluído no Histórico.
- Responsável pela informação (`supabase/responsavel.sql`, 10/11/2026): campo opcional (deixou de ser obrigatório em 10/11/2026, a pedido do usuário) ao registrar molhagem e saída de frota (quem passou a informação; o último informado fica preenchido no aparelho). Aparece no painel ("Informado por" no cartão do ponto e na frota em trajeto), na imagem do painel, no relatório e no Histórico. Na chegada do trajeto, a molhagem leva o responsável da saída.
- Exportação: **Imagem do painel (PNG)** gera os cartões do painel e **Exportar PNG** gera o relatório em tabelas, cada um numa imagem única e contínua (sem quebra de página). A mesma imagem do painel é a que o robô envia no WhatsApp (repositório `envio-whatsapp-poeira`).
- Editar molhagem (`supabase/editar_molhagem.sql`, 11/11/2026): no **Histórico**, o administrador tem o botão **Editar** em cada molhagem para corrigir data e hora, ponto, frota, motorista, responsável pela informação e observação. Operador e consulta não editam. O banco guarda quem editou e quando (`editado_por`, `editado_em`).
- Caminhões por frente (`supabase/trelas_caminhoes.sql`, 25/11/2026): aba **Caminhões** com um quadro por frente e cada caminhão canavieiro como **carregado**, **vazio** ou **parado** (com motivo) e há quanto tempo está assim. Administrador e operador tocam no caminhão para trocar a frente ou a situação; consulta só acompanha. Toda troca fica em "Mudanças nas últimas 24 horas".
- Trelas quebradas (mesmo arquivo, 25/11/2026): aba **Trelas** para registrar a trela que quebrou no trajeto (caminhão, 1ª/2ª trela, frente, local, motivo, hora, responsável). O caminhão passa a **parado** ("Trela quebrada") na aba Caminhões, se a opção estiver marcada. Em **Resolvido** informa-se a hora, o que foi feito e se o caminhão volta vazio ou carregado; o sistema calcula o tempo parado. Mostra paradas agora, quebras por motivo e por caminhão e o histórico; só o administrador exclui registros.
- Caminhões canavieiros e frentes são cadastrados na aba **Cadastros** (antes "Frotas e pontos"), separados dos caminhões-pipa.
