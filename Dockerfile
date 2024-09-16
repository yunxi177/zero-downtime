FROM node:18.20.4-bullseye

WORKDIR /usr/src/app

COPY package*.json ./

RUN npm config set registry https://mirrors.huaweicloud.com/repository/npm/ && npm install
COPY . .

EXPOSE 3000
CMD [ "node", "server.js" ]
