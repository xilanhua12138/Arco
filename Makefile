.PHONY: build test helpers app package gpt-live-probe clean

build:
	cargo build --manifest-path rust/arco-core/Cargo.toml --lib
	swift build --package-path macos/ArcoNativeUI --product Arco -j 1

test:
	./native/verify-native-ui.sh
	cargo test --manifest-path rust/arco-audio-rt/Cargo.toml --all-targets -- --test-threads=1
	cargo test --manifest-path rust/arco-core/Cargo.toml --all-targets --all-features -- --test-threads=1
	cargo test --manifest-path rust/arco-gpt-live/Cargo.toml --all-targets -- --test-threads=1
	cargo build --manifest-path rust/arco-core/Cargo.toml --lib
	@set -e; for product in \
		ArcoNativeUIContractTests \
		ArcoProviderPresentationContractTests \
		ArcoMarkdownContractTests \
		ArcoTopBarContractTests \
		ArcoContentSourceParityContractTests \
		ArcoHistoryPerformanceContractTests \
		ArcoSettingsParityContractTests \
		ArcoSetupSourceParityContractTests \
		ArcoOverlaySourceParityContractTests \
		ArcoWindowChromeContractTests \
		ArcoPreferencesContractTests \
		ArcoLocalizationContractTests \
		ArcoMeetingAwarenessContractTests; do \
		swift run --package-path macos/ArcoNativeUI "$$product"; \
	done
	./native/build-recorder.sh
	./native/recorder --self-test
	swift run --package-path native/local-transcriber arco-transcription-selftest

helpers:
	./native/build-recorder.sh
	./native/build-gpt-live.sh
	./native/build-deepgram-transcriber.sh
	./native/build-elevenlabs-transcriber.sh
	./native/build-doubao-transcriber.sh
	./native/build-local-transcriber.sh

app: helpers
	./native/build-native-app.sh

package:
	./native/package-local-app.sh

gpt-live-probe:
	cargo run --manifest-path rust/arco-gpt-live/Cargo.toml --bin arco-gpt-live-probe -- media

clean:
	cargo clean --manifest-path rust/arco-audio-rt/Cargo.toml
	cargo clean --manifest-path rust/arco-core/Cargo.toml
	cargo clean --manifest-path rust/arco-gpt-live/Cargo.toml
	swift package --package-path macos/ArcoNativeUI clean
	rm -rf build artifacts
