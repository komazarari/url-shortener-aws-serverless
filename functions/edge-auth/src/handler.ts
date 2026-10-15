import type { CloudFrontRequestEvent, CloudFrontRequestResult } from 'aws-lambda';
import { authenticate } from './auth.js';

export const handler = async (
  event: CloudFrontRequestEvent,
): Promise<CloudFrontRequestResult> => {
  const request = event.Records[0].cf.request;
  const result = await authenticate(request);

  // Returning the request unchanged lets CloudFront continue to the origin.
  return result.authenticated ? request : result.response;
};
