# advance.sh

> Drop one script. Advance every repo.

**advance.sh** is a shell script you add to any git repository. Run it once
and an AI agent makes one meaningful improvement, opens a pull request, and
enters it into the contribution reward pool.

## Quick start

```bash
# 1. Download
curl -fsSL https://raw.githubusercontent.com/pierce403/advance.sh/main/advance.sh \
     -o advance.sh && chmod +x advance.sh

# 2. Export your OpenAI API key
export OPENAI_API_KEY=sk-...

# 3. Run
./advance.sh
```

The script will scan your repo, ask the LLM for **one concrete improvement**
(a "ralph loop"), apply the change on a new branch, and open a pull request.

## How it works

1. **Scan** — reads your file tree and recent commits
2. **Ralph loop** — an LLM picks the highest-value small improvement it can make
3. **Commit** — change is applied on `advance/<topic>` branch
4. **Pull request** — opened automatically via `gh` CLI or a browser link
5. **Rating & rewards** — an evaluation agent scores the PR; excellent
   contributions earn token rewards from the pool

## Configuration

| Variable | Default | Description |
|---|---|---|
| `OPENAI_API_KEY` | *(required)* | API key for your LLM provider |
| `ADVANCE_API_URL` | `https://api.openai.com/v1/chat/completions` | Any OpenAI-compatible endpoint |
| `ADVANCE_MODEL` | `gpt-4o` | Model name |
| `ADVANCE_MAX_TOKENS` | `4096` | Max tokens in the LLM response |
| `ADVANCE_EXCLUDE_EXTENSIONS` | `png\|jpg\|gif\|...` | `\|`-separated list of file extensions to skip when sampling file contents |

## Website

The project website lives at [`index.html`](index.html) and explains the
concept in detail, including the contribution rating system.

## License

Apache 2.0 — see [LICENSE](LICENSE).

