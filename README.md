# Barreto Manutenção

App de demandas de manutenção, cotações, aprovação por alçada e ordens de compra da Barreto Transportes.
Funciona no celular e no computador e pode ser instalado como aplicativo.

## Arquivos
- `index.html` — o app
- `config.js` — endereço e chave pública do Supabase (projeto barreto-manutencao)
- `manifest.webmanifest`, `sw.js`, `icons/`, `logo.png` — instalação e identidade
- `supabase/schema.sql` — banco de dados (já aplicado no projeto; guarde como referência)

## Usuários
- Login por **celular + senha** (sem SMS). O gestor cria cada pessoa no app: Cadastros › Usuários › Usuário
  (nome, celular, senha provisória, perfil e placa) e redefine senhas pelo mesmo lugar.
- Quem tem login por e-mail continua entrando com o e-mail.
- A criação e a troca de senha passam pela função `supabase/functions/admin-usuarios`, que só aceita pedidos de gestor.

## Regras (editáveis em Regras e alçadas)
Alçadas por perfil, cotações exigidas por faixa de valor, teto da compra emergencial,
prazo para anexar NF e tolerância da NF. As regras são conferidas no banco, não só na tela.
