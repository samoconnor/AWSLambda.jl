all: jl_lambda_base.master.zip \
     jl_lambda_base.0.6.0.zip \
     jl_lambda_base.0.5.2.zip

lambdajlsrc/image:
	docker build -t lambdajlsrc lambdajlsrc
	touch $@

lambdajlbase/image.%: lambdajlsrc/image
	docker build \
		--build-arg JL_VERSION=$* \
		-t lambdajlbase:$* lambdajlbase
	touch $@

jl_lambda_base.%.zip: lambdajlbase/image.%
	docker run -v $(PWD):/var/host -ti lambdajlbase:$* bash /var/host/build.sh $@

clean:
	rm -f lambdajlsrc/image
	rm -f lambdajlbase/image.*
	rm -f jl_lambda_base.*.zip
