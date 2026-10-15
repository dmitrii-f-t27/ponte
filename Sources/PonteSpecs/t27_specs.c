// Emits the function bodies of the generated t27 headers once. Rewritten by Specs/generate.sh.
// t27c writes every condition in double parentheses: if ((a == b)). Package.swift passes no warning
// flags, so the warning generate.sh turns off with -Wno-parentheses-equality is turned off here.
#pragma clang diagnostic ignored "-Wparentheses-equality"
#include "analysis_rules.h"
#include "audio_rules.h"
#include "camera_rules.h"
#include "context_rules.h"
#include "device_rules.h"
#include "lane_rules.h"
#include "peer_rules.h"
#include "segment_rules.h"
#include "text_rules.h"
#include "transcript_rules.h"
#include "ui_rules.h"
#include "voice_rules.h"
