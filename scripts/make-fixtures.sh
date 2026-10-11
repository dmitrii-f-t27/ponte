#!/bin/zsh
# Regenerates the speech test fixtures (gitignored): fixtures/pt_*.wav (say -v Luciana)
# and fixtures/ru_*.wav (say -v Milena), 16 kHz mono 16-bit WAV.
# Owned by the speech agent. Usage: scripts/make-fixtures.sh
set -euo pipefail

root="${0:A:h:h}"
out="$root/fixtures"
mkdir -p "$out"

pt=(
  "Bom dia, Dmitrii. Obrigado por participar da reunião de hoje. Vamos revisar o contrato e os prazos de entrega."
  "Podemos enviar a proposta até sexta-feira, mas precisamos confirmar o orçamento com o nosso diretor financeiro."
  "O valor total é de quarenta e cinco mil reais, com pagamento em três parcelas."
  "Então, como eu estava dizendo, a equipe de vendas está trabalhando no projeto novo com os clientes de São Paulo e do Rio de Janeiro, e a gente espera fechar pelo menos três contratos até o final do trimestre, desde que o time técnico consiga entregar a integração a tempo."
)
ru=(
  "Добрый день! Спасибо, что нашли время для звонка. Давайте обсудим условия договора."
  "Мы можем начать поставки в следующем месяце, если вы подтвердите заказ до пятницы."
  "Общая сумма составляет сорок пять тысяч реалов, оплата в три этапа."
  "Простите, вас плохо слышно. Можете повторить последний вопрос?"
)

convert() {  # $1 = input aiff, $2 = output wav
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -hide_banner -loglevel error -y -i "$1" -ar 16000 -ac 1 -c:a pcm_s16le "$2"
  else
    afconvert -f WAVE -d LEI16@16000 -c 1 "$1" "$2"
  fi
}

render() {  # $1 = voice, $2 = prefix, rest = phrases
  local voice=$1 prefix=$2 i=1
  shift 2
  for phrase in "$@"; do
    local aiff="$out/${prefix}_$i.aiff" wav="$out/${prefix}_$i.wav"
    say -v "$voice" -o "$aiff" -- "$phrase"
    convert "$aiff" "$wav"
    rm -f "$aiff"
    printf '%s  %s\n' "$wav" "$phrase"
    i=$((i + 1))
  done
}

render Luciana pt "${pt[@]}"
render Milena ru "${ru[@]}"
