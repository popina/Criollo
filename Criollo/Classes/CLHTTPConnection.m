//
//  CLHTTPConnection.m
//  Criollo
//
//  Created by Cătălin Stan on 28/04/15.
//
//

#import <Criollo/CLApplication.h>
#import <Criollo/CLHTTPRequest.h>
#import <Criollo/CLHTTPResponse.h>
#import <Criollo/GCDAsyncSocket.h>

#import "CLHTTPConnection.h"
#import "CLApplication+Internal.h"

@interface CLHTTPConnection () <GCDAsyncSocketDelegate> {
    CLHTTPRequest* request;
    CLHTTPResponse* response;
    
    NSUInteger requestBodyLength;
    NSUInteger requestBodyReceivedBytesLength;
}

- (void)initialize;

- (void)didReceiveRequestHeaders;
- (void)didReceiveRequestHeaderData:(NSData*)data;

- (void)didReceiveRequestBody;
- (void)didReceiveRequestBodyData:(NSData*)data;

- (void)didReceiveCompleteRequest;

- (void)handleError:(CLError)errorType object:(id)object;

- (BOOL)shouldCloseConnection;

@end

@implementation CLHTTPConnection

- (instancetype)init
{
    return [self initWithSocket:nil delegateQueue:nil];
}

- (instancetype)initWithSocket:(GCDAsyncSocket *)socket
{
    NSString* acceptedSocketDelegateQueueLabel = [[NSBundle mainBundle].bundleIdentifier stringByAppendingPathExtension:[NSString stringWithFormat:@"SocketDelegateQueue-%hu", socket.connectedPort]];
    dispatch_queue_t acceptedSocketDelegateQueue = dispatch_queue_create([acceptedSocketDelegateQueueLabel cStringUsingEncoding:NSASCIIStringEncoding], NULL);
    return  [self initWithSocket:socket delegateQueue:acceptedSocketDelegateQueue];
}

- (instancetype)initWithSocket:(GCDAsyncSocket *)socket delegateQueue:(dispatch_queue_t)delegateQueue
{
    self = [super init];
    if (self != nil) {
        if (socket != nil ) {
            self.socket = socket;
            [self.socket setDelegate:self delegateQueue:delegateQueue];
            request = [[CLHTTPRequest alloc] init];
            dispatch_async(self.socket.delegateQueue, ^{ @autoreleasepool {
                [self initialize];
            }});
        }
    }
    return self;
}

- (void)dealloc
{
//    NSLog(@"%s", __PRETTY_FUNCTION__);
    
    [self.socket setDelegate:nil delegateQueue:NULL];
    [self.socket disconnect];
}

#pragma mark - Request Processing

- (void)initialize
{
//    NSLog(@"%s", __PRETTY_FUNCTION__);
    
    requestBodyReceivedBytesLength = 0;
    requestBodyLength = 0;
    
    [self.socket readDataToData:[GCDAsyncSocket CRLFData] withTimeout:CLSocketReadInitialTimeout maxLength:CLRequestMaxHeaderLineLength tag:CLSocketTagBeginReadingRequest];

}

- (void)didReceiveRequestHeaders
{
//    NSLog(@"%s", __PRETTY_FUNCTION__);
//    NSLog(@"%@", request.allHTTPHeaderFields);
}

- (void)didReceiveRequestHeaderData:(NSData *)data
{
//    NSLog(@"%s %lu bytes", __PRETTY_FUNCTION__, data.length);
}

- (void)didReceiveRequestBody
{
//    NSLog(@"%s", __PRETTY_FUNCTION__);
}

- (void)didReceiveRequestBodyData:(NSData*)data
{
//    NSLog(@"%s %lu bytes", __PRETTY_FUNCTION__, data.length);
}

- (void)didReceiveCompleteRequest
{
    [[CLApp workerQueue] addOperationWithBlock:^{
        response = [[CLHTTPResponse alloc] initWithHTTPConnection:self HTTPStatusCode:200];
        [response setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
        [response setValue:@"text/html; charset=utf-8" forHTTPHeaderField:@"Content-type"];
        [response setValue:@"chunked" forHTTPHeaderField:@"Transfer-encoding"];        
        [response writeString:@"<h1>Hello world!</h1>"];
//        @synchronized([CLApp connections]) {
//            [response writeFormat:@"<pre>Conntections: %lu</pre>", [CLApp connections].count];
//        }
        [response finish];
    }];
    
//    NSLog(@"%s", __PRETTY_FUNCTION__);
}

- (void)handleError:(CLError)errorType object:(id)object
{
//    NSLog(@"%s %lu %@", __PRETTY_FUNCTION__, errorType, object);

    NSUInteger statusCode = 500;
    
    switch (errorType) {
        case CLErrorRequestMalformedRequest:
            statusCode = 400;
            [CLApp logErrorFormat:@"Malformed request: %@", [[NSString alloc] initWithData:object encoding:NSUTF8StringEncoding] ];
            break;
            
        case CLErrorRequestUnsupportedMethod:
            statusCode = 405;
            [CLApp logErrorFormat:@"Unsuppoerted method %@ for path %@", [object method], [object URL]];
            break;
            
        default:
            break;
    }
    
    response = [[CLHTTPResponse alloc] initWithHTTPConnection:self HTTPStatusCode:statusCode];
    [response setValue:@"0" forHTTPHeaderField:@"Content-length"];
    [response setValue:@"close" forHTTPHeaderField:@"Connection"];
    [response end];
}

- (BOOL)shouldCloseConnection
{

    BOOL shouldClose = NO;
    NSString *connection = [request valueForHTTPHeaderField:@"Connection"];
    if ( connection != nil ) {
        shouldClose = [connection caseInsensitiveCompare:@"close"] == NSOrderedSame;
    }
//    shouldClose = YES;
    return shouldClose;
}

#pragma mark - GCDAsyncSocketDelegate

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData*)data withTag:(long)tag
{
//    NSLog(@"%s %lu bytes", __PRETTY_FUNCTION__, data.length);
    
    if (tag == CLSocketTagBeginReadingRequest || tag == CLSocketTagReadingRequestHeader)
    {
        BOOL result = [request appendData:data];
        if (!result) {
            
            // This is the first read, and it went wrong
            [self handleError:CLErrorRequestMalformedRequest object:data];
            return;
            
        } else if ( !request.headerComplete ) {

            [self didReceiveRequestHeaderData:data];
            
            // Continue to read until we get all the headers
            [self.socket readDataToData:[GCDAsyncSocket CRLFData] withTimeout:CLSocketReadHeaderLineTimeout maxLength:CLRequestMaxHeaderLineLength tag:CLSocketTagReadingRequestHeader];
            
        } else {
            
            [self didReceiveRequestHeaderData:data];
            [self didReceiveRequestHeaders];
            
            // We have all the headers
            if ( ![CLApp canHandleRequest:request] ) {
                [self handleError:CLErrorRequestUnsupportedMethod object:request];
                return;
            }
            
            requestBodyLength = [request valueForHTTPHeaderField:@"Content-Length"].integerValue;
            
            if ( requestBodyLength > 0 ) {
                NSUInteger bytesToRead = requestBodyLength < CLRequestBodyBufferSize ? requestBodyLength : CLRequestBodyBufferSize;
                [self.socket readDataToLength:bytesToRead withTimeout:CLSocketReadBodyTimeout tag:CLSocketTagReadingRequestBody];
            } else {
                [self didReceiveCompleteRequest];
            }
            
        }
    } if ( tag == CLSocketTagReadingRequestBody ) {

        requestBodyReceivedBytesLength += data.length;
        [self didReceiveRequestBodyData:data];
        
        if (requestBodyReceivedBytesLength < requestBodyLength) {
            NSUInteger requestBodyLeftBytesLength = requestBodyLength - requestBodyReceivedBytesLength;
            NSUInteger bytesToRead = requestBodyLeftBytesLength < CLRequestBodyBufferSize ? requestBodyLeftBytesLength : CLRequestBodyBufferSize;
            
            [self.socket readDataToLength:bytesToRead withTimeout:CLSocketReadBodyTimeout tag:CLSocketTagReadingRequestBody];
        } else {
            [self didReceiveCompleteRequest];
        }
        
    }
}

- (void)socket:(GCDAsyncSocket *)sock didWriteDataWithTag:(long)tag
{
//    NSLog(@"%s", __PRETTY_FUNCTION__);
 
    if ( tag == CLSocketTagFinishSendingResponseAndClosing || tag == CLSocketTagFinishSendingResponse ) {
        request = nil;
        response = nil;
        
        if ( tag == CLSocketTagFinishSendingResponseAndClosing || self.shouldCloseConnection) {
            [self.socket disconnect];
            return;
        } else {
            request = [[CLHTTPRequest alloc] init];
            [self initialize];
        }
        
    } else {

    }
    
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err
{
//    NSLog(@"%s", __PRETTY_FUNCTION__);
    
    self.socket = nil;
    request = nil;
    response = nil;

    dispatch_queue_t queue = [CLApplication sharedApplication].delegateQueue;
    dispatch_async(queue, ^{ @autoreleasepool {
        [CLApp socketDidDisconnect:self.socket withError:err];
        [CLApp didCloseConnection:self];
    }});
}

@end
