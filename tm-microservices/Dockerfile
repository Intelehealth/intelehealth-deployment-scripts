# Stage 1: Clone source and install production dependencies
FROM node:18-alpine AS builder

RUN apk add --no-cache git

WORKDIR /app

RUN git clone --depth=1 \
    --branch unicef-krygz-master \
    https://github.com/Intelehealth/intelehealth-backend-service.git .

RUN npm ci --omit=dev

# Stage 2: Lean production runtime image
FROM node:18-alpine

WORKDIR /app

COPY --from=builder /app .

EXPOSE 3004

CMD ["node", "./bin/www"]
