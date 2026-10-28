.PHONY: build run clean verify test

build:          ## 编译并打包成 build/MailPilot.app
	./scripts/build.sh

run: build      ## 构建并启动
	./scripts/run.sh

clean:          ## 删除构建产物
	./scripts/clean.sh

verify:         ## 只编译不打包，用于快速检查错误
	swift build -c release --disable-sandbox

test:           ## 断言测试（合成 .emlx，不需要 FDA）
	./scripts/test.sh
