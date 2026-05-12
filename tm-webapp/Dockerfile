# Stage 1: Build
FROM node:18-alpine AS builder

WORKDIR /app

# Clone specific branch
RUN apk add --no-cache git && \
    git clone --depth=1 --branch unicef_krygz_dev_master \
    https://github.com/Intelehealth/intelehealth-doctor-webapp.git .

# Install dependencies
RUN npm ci --legacy-peer-deps

# Build production bundle
RUN npm run build -- --configuration production --aot

# Stage 2: Serve
FROM nginx:1.25-alpine

# Remove default nginx static assets
RUN rm -rf /usr/share/nginx/html/*

# Copy built Angular app
COPY --from=builder /app/dist/intelehealth-ui /usr/share/nginx/html

# Copy nginx config
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
