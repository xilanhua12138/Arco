.PHONY: build test helpers app package clean

build:
	cargo build --manifest-path rust/arco-core/Cargo.toml --lib
	swift build --package-path macos/ArcoNativeUI --product Arco -j 1

test:
	./native/verify-native-ui.sh
	cargo test --manifest-path rust/arco-core/Cargo.toml --all-targets --all-features -- --test-threads=1
	@set -e; for product in \
		ArcoNativeUIContractTests \
		ArcoMarkdownContractTests \
		ArcoTopBarContractTests \
		ArcoContentSourceParityContractTests \
		ArcoHistoryPerformanceContractTests \
		ArcoSettingsParityContractTests \
		ArcoSetupSourceParityContractTests \
		ArcoOverlaySourceParityContractTests \
		ArcoWindowChromeContractTests \
		ArcoPreferencesContractTests \
		ArcoLocalizationContractTests; do \
		swift run --package-path macos/ArcoNativeUI "$$product"; \
	done
	./native/build-recorder.sh
	./native/recorder --self-test
	swift run --package-path native/local-transcriber arco-transcription-selftest

helpers:
	./native/build-recorder.sh
	./native/build-deepgram-transcriber.sh
	./native/build-elevenlabs-transcriber.sh
	./native/build-doubao-transcriber.sh
	./native/build-local-transcriber.sh

app: helpers
	./native/build-native-app.sh

package:
	./native/package-local-app.sh

clean:
	cargo clean --manifest-path rust/arco-core/Cargo.toml
	swift package --package-path macos/ArcoNativeUI clean
	rm -rf build artifacts
