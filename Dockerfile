FROM ruby:2.3
RUN \
  apt-get update && \
  apt-get install -y build-essential git libreadline-dev libncurses5-dev libpcre3-dev libssl-dev libluajit-5.1-dev luarocks wget && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

RUN \
  mkdir /src && cd /src && \
  git clone https://github.com/alibaba/tengine.git --single-branch --depth 1 . && \
  mkdir -p /var/lib/nginx && \
  ./configure \
    --prefix=/etc/nginx \
    --conf-path=/etc/nginx/nginx.conf \
    --sbin-path=/usr/bin/nginx \
    --pid-path=/run/nginx.pid \
    --lock-path=/run/lock/nginx.lock \
    --user=www-data \
    --group=www-data \
    --http-log-path=/var/log/nginx/access.log \
    --error-log-path=stderr \
    --http-client-body-temp-path=/var/lib/nginx/client-body \
    --http-proxy-temp-path=/var/lib/nginx/proxy \
    --http-fastcgi-temp-path=/var/lib/nginx/fastcgi \
    --http-scgi-temp-path=/var/lib/nginx/scgi \
    --http-uwsgi-temp-path=/var/lib/nginx/uwsgi \
    --with-ipv6 \
    --with-pcre-jit \
    --with-file-aio \
    --with-http_realip_module \
    --with-http_stub_status_module \
    --with-http_addition_module \
    --with-http_degradation_module \
    --with-http_lua_module \
    --with-http_sub_module && \
  make && \
  make install && \
  make clean && \
  cd / && rm -rf /src && \
  ldconfig

RUN mkdir -p /usr/src/app
WORKDIR /usr/src/app
COPY Gemfile /usr/src/app/
COPY Gemfile.lock /usr/src/app/
RUN bundle install
COPY . /usr/src/app

VOLUME /etc/nginx
EXPOSE 80 8080 443

CMD ["./docker-nginx.rb"]
