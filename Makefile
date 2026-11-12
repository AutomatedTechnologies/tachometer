# Tachometer — file manifest + build rules.
#
# This Makefile is the build's bill of materials: SOURCES and RESOURCES
# are the complete file list. build.sh is a thin wrapper over these targets.
#
#   make check   syntax-check every source against the MacOSX10.13 SDK
#                (Linux VM recipe per estate TOOLS.md; no link, no run)
#   make app     assemble Tachometer.app (macOS only)

SOURCES = \
	Tachometer/main.m \
	Tachometer/AppDelegate.m \
	Tachometer/AcademyWelcomeController.m \
	Tachometer/AcademyAppIconView.m \
	Tachometer/MainController.m \
	Tachometer/ProcSampler.m \
	Tachometer/SampleStore.m \
	Tachometer/BudgetScorer.m \
	Tachometer/CPUMath.c

HEADERS = \
	Tachometer/AppDelegate.h \
	Tachometer/AcademyWelcomeController.h \
	Tachometer/AcademyAppIconView.h \
	Tachometer/MainController.h \
	Tachometer/ProcSampler.h \
	Tachometer/SampleStore.h \
	Tachometer/BudgetScorer.h \
	Tachometer/CPUMath.h

# startup-sound.wav: byte-identical to the SDS-10 library master,
# SHA-256 07a113244c6b432b22954a089ce519bd239311b14a48f26ae85214ed8c25b09a.
RESOURCES = \
	Tachometer/Resources/startup-sound.wav \
	Tachometer/Resources/LICENSE-ACADEMY.txt \
	Tachometer/Resources/NOTICE.txt \
	Tachometer/Resources/budgets-v1.json

SDK ?= $(HOME)/workspace/tools/sdks/MacOSX10.13.sdk
CLANG ?= clang
OBJCFLAGS = -target x86_64-apple-darwin17 -isysroot $(SDK) \
	-fobjc-runtime=macosx-10.13 -fobjc-arc -fsyntax-only -ITachometer
CFLAGS = -target x86_64-apple-darwin17 -isysroot $(SDK) \
	-fsyntax-only -ITachometer

.PHONY: check app
check:
	@for src in $(SOURCES); do \
		case "$$src" in \
			*.c) echo "== $$src"; $(CLANG) $(CFLAGS) $$src || exit 1 ;; \
			*)   echo "== $$src"; $(CLANG) $(OBJCFLAGS) $$src || exit 1 ;; \
		esac; \
	done
	@echo "ALL SYNTAX OK"

app:
	if [ "$$(uname)" != "Darwin" ]; then \
		echo "make app requires macOS (system clang + AppKit)" >&2; exit 1; \
	fi
	rm -rf Tachometer.app
	mkdir -p Tachometer.app/Contents/MacOS Tachometer.app/Contents/Resources
	$(CLANG) -target x86_64-apple-macos10.13 -fobjc-arc -ITachometer \
		-framework AppKit -framework Foundation \
		-o Tachometer.app/Contents/MacOS/Tachometer $(SOURCES)
	cp Tachometer/Info.plist Tachometer.app/Contents/Info.plist
	cp $(RESOURCES) Tachometer.app/Contents/Resources/
	@echo "Tachometer.app assembled — launch with: open Tachometer.app"
