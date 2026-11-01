# Langfuse Observability Plugin for Antigravity CLI

Envia automaticamente os traces de sessão, prompts do usuário, respostas do modelo (`PLANNER_RESPONSE` com tokens, thinking e tool calls) e resultados de ferramentas para o **Langfuse** (Cloud ou On-Premise) ao final de cada turno (`Stop` hook), utilizando **OTLP HTTP JSON** (`/api/public/otel/v1/traces`).

## Instalação

Diretamente via GitHub:

```bash
agy plugin install https://github.com/uaiso-serious/agy-langfuse-plugin
```

Ou a partir de um clone local (ex.: desenvolvimento ou espelho OneDev):

```bash
git clone https://github.com/uaiso-serious/agy-langfuse-plugin.git /tmp/langfuse-observability
agy plugin validate --strict /tmp/langfuse-observability
agy plugin install /tmp/langfuse-observability
```

## Variáveis de Ambiente

```dotenv
LANGFUSE_PUBLIC_KEY=pk-lf-...
LANGFUSE_SECRET_KEY=sk-lf-...
# Opcional (default: https://cloud.langfuse.com)
LANGFUSE_BASE_URL=http://langfuse.example.com
# Opcional (fallback: e-mail de GIT_CO_AUTHOR > GIT_USER_EMAIL > GIT_USER_NAME > USER)
LANGFUSE_USER_ID=some-user
# Opcional (tags extras separadas por vírgula)
AGY_LANGFUSE_TRACE_TAGS=mode:interactive
# Opcional (limite de caracteres por campo de texto, default: 20000)
AGY_LANGFUSE_MAX_CHARS=20000
```
