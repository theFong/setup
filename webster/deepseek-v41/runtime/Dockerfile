# syntax=docker/dockerfile:1

ARG UPSTREAM_VLLM_IMAGE
FROM ${UPSTREAM_VLLM_IMAGE}

ARG VLLM_COMMIT
ARG VLLM_BUILD_BASE_IMAGE_DIGEST
ARG VLLM_FINAL_BASE_IMAGE_DIGEST
LABEL ai.webster.vllm.commit="${VLLM_COMMIT}" \
      ai.webster.vllm.build-base-digest="${VLLM_BUILD_BASE_IMAGE_DIGEST}" \
      ai.webster.vllm.final-base-digest="${VLLM_FINAL_BASE_IMAGE_DIGEST}"
