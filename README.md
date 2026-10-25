# Barreto Manutenção

App de demandas de manutenção, cotações, aprovação por alçada e ordens de compra da Barreto Transportes.
Funciona no celular e no computador e pode ser instalado como aplicativo.

## Arquivos
- `index.html` — o app
- `config.js` — endereço e chave pública do Supabase (projeto barreto-manutencao)
- `manifest.webmanifest`, `sw.js`, `icons/`, `logo.png` — instalação e identidade
- `supabase/schema.sql` — banco de dados (já aplicado no projeto; guarde como referência)

## Primeiro acesso
1. No Supabase, projeto **barreto-manutencao** › Authentication › Users › Add user › Create new user.
   Crie o SEU usuário primeiro (o primeiro usuário vira gestor). Marque "Auto Confirm User".
2. Authentication › URL Configuration › Site URL: coloque o endereço do app no GitHub Pages
   (necessário para o link de "Esqueci minha senha").
3. Abra o app, entre com e-mail e senha, cadastre veículos e fornecedores em Cadastros.
4. Para cada pessoa: crie o usuário no Supabase (passo 1) e ajuste nome, perfil e placa em Cadastros › Usuários.

## Regras (editáveis em Regras e alçadas)
Alçadas por perfil, cotações exigidas por faixa de valor, teto da compra emergencial,
prazo para anexar NF e tolerância da NF. As regras são conferidas no banco, não só na tela.
