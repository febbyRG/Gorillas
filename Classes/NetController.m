//
//  NetController.m
//  Gorillas
//
//  Created by Maarten Billemont on 13/11/10.
//  Copyright 2010 lhunath (Maarten Billemont). All rights reserved.
//

#import <unistd.h>

#import "NetController.h"
#import "StringUtils.h"
#import "GorillasAppDelegate.h"
#import "CityTheme.h"


@interface NetController ()

@property (nonatomic, readwrite, retain) GKMatch                *match;
@property (nonatomic, readwrite, retain) NetMessageElectHost    *hostElection;

- (GorillaLayer *)findGorillaWithPlayerID:(NSString *)playerID;

@end

@implementation NetController
@synthesize match = _match, hostElection = _hostElection;

- (void)beginRequest:(GKMatchRequest *)aMatchRequest {
    
    [[GorillasAppDelegate get].gameLayer stopGame];
    NSAssert(![[GorillasAppDelegate get].gameLayer checkGameStillOn], @"A previous match is still running.");
    NSAssert(self.match == nil && !started, @"A previous match has not been cleaned up.");
    
    GKMatchmakerViewController *matchVC = [[GKMatchmakerViewController alloc] initWithMatchRequest:aMatchRequest];
    matchVC.matchmakerDelegate = self;
    [[[UIApplication sharedApplication] keyWindow].rootViewController presentModalViewController:matchVC animated:YES];
    [matchVC release];
}

- (void)beginInvite:(GKInvite *)anInvite {
    
    [[GorillasAppDelegate get].gameLayer stopGame];
    NSAssert(![[GorillasAppDelegate get].gameLayer checkGameStillOn], @"A previous match is still running.");
    NSAssert(self.match == nil && !started, @"A previous match has not been cleaned up.");
    
    GKMatchmakerViewController *matchVC = [[GKMatchmakerViewController alloc] initWithInvite:anInvite];
    matchVC.matchmakerDelegate = self;
    [[[UIApplication sharedApplication] keyWindow].rootViewController presentModalViewController:matchVC animated:YES];
    [matchVC release];
}

- (void)endMatch {
    
    started = NO;

    [self.hostElection cleanup];
    self.hostElection = nil;
    
    [self.match disconnect];
    self.match = nil;
}

- (void)throwBy:(NSString *)playerID velocity:(CGPoint)velocity {
    
    dbg(@"Sending throw of: %@ by: %@ to all players.", playerID, NSStringFromCGPoint(velocity));
    NSError *error = nil;
    if (![self.match sendDataToAllPlayers:[NSKeyedArchiver archivedDataWithRootObject:[NetMessageThrow throwWithPlayerID:playerID velocity:velocity]]
                             withDataMode:GKMatchSendDataReliable error:&error] || error) {
        err(@"Failed to send our throw: %@", error);
        [self endMatch];
        return;
    }
}

// The user has cancelled matchmaking
- (void)matchmakerViewControllerWasCancelled:(GKMatchmakerViewController *)viewController {
    
    [self endMatch];

    [[[UIApplication sharedApplication] keyWindow].rootViewController dismissModalViewControllerAnimated:YES];
}

// Matchmaking has failed with an error
- (void)matchmakerViewController:(GKMatchmakerViewController *)viewController didFailWithError:(NSError *)error {
    
    err(@"Matchmaker failed: %@", error);
    [self endMatch];
    
    [[[UIApplication sharedApplication] keyWindow].rootViewController dismissModalViewControllerAnimated:YES];
}

// A peer-to-peer match has been found, the game should start
- (void)matchmakerViewController:(GKMatchmakerViewController *)viewController didFindMatch:(GKMatch *)aMatch {
    
    self.match = aMatch;
    self.match.delegate = self;
}

- (void)match:(GKMatch *)match didReceiveData:(NSData *)data fromPlayer:(NSString *)playerID {
    
    NetMessage *message = [NSKeyedUnarchiver unarchiveObjectWithData:data];
    dbg(@"Received data from: %@, message: %@", playerID, message);
    if ([message isKindOfClass:[NetMessageElectHost class]]) {
        NetMessageElectHost *electMessage = (NetMessageElectHost *)message;
        [self.hostElection addVote:electMessage fromPlayer:playerID];
        dbg(@" -> Host Election: %d", electMessage.vote);
        dbg(@" -> Winning host: %@ (%@), ordered hosts: %@",
            self.hostElection.hostID, [self.hostElection isLocalHost]? @"local": @"remote", self.hostElection.orderedPlayerIDs);
        
        if (!started && self.hostElection.host) {
            // Beginning of the game, host determined.  Start the game.
            started = YES;
            [[[UIApplication sharedApplication] keyWindow].rootViewController dismissModalViewControllerAnimated:YES];
            
            // Use the host's seed for the game random.
            [[GorillasConfig get] setGameRandomSeed:self.hostElection.host.vote];
            [GorillasConfig get].cityTheme = [[CityTheme getThemeNames] objectAtIndex:gameRandom() % [[CityTheme getThemeNames] count]];
            
            NSUInteger gameConfigurationIndex = [[GorillasConfig get].activeGameConfigurationIndex unsignedIntValue];
            GameConfiguration *gameConfiguration = [[GorillasConfig get].gameConfigurations objectAtIndex:gameConfigurationIndex];
            
            [[GorillasAppDelegate get].gameLayer configureGameWithMode:gameConfiguration.mode
                                                               playerIDs:self.hostElection.orderedPlayerIDs ais:gameConfiguration.multiplayerAICount];
            [[GorillasAppDelegate get].gameLayer startGameHosted:[self.hostElection isLocalHost]];
        }
    }
    else if ([message isKindOfClass:[NetMessageThrow class]]) {
        NetMessageThrow *throwMessage = (NetMessageThrow *)message;
        dbg(@"Received throw of: %@ by: %@ from player: %@", throwMessage.playerID, NSStringFromCGPoint(throwMessage.velocity), playerID);
        [[GorillasAppDelegate get].gameLayer.cityLayer throwFrom:[self findGorillaWithPlayerID:throwMessage.playerID]
                                                    withVelocity:throwMessage.velocity];
    }
    else
        err(@"Did not understand data unarchived as: %@\n%@", message, data);
}

// Called when a player connects to or disconnects from the match.
- (void)match:(GKMatch *)match player:(NSString *)playerID didChangeState:(GKPlayerConnectionState)state {
    
    GorillaLayer *gorilla = [self findGorillaWithPlayerID:playerID];
    if (gorilla)
        gorilla.connectionState = state;
    else
        err(@"No gorilla found for player: %@", playerID);
    
    if (!started && !match.expectedPlayerCount) {
        // Beginning of the game, all players have connected.  Vote for host.
        NSError *error = nil;
        self.hostElection = [NetMessageElectHost electHostWithPlayerIDs:self.match.playerIDs];
        if (![self.match sendDataToAllPlayers:[NSKeyedArchiver archivedDataWithRootObject:self.hostElection]
                                 withDataMode:GKMatchSendDataReliable error:&error] || error) {
            err(@"Failed to send our host election: %@", error);
            [self endMatch];
            return;
        }
    }
}

// Called when the match failed to connect to a player.
- (void)match:(GKMatch *)match connectionWithPlayerFailed:(NSString *)playerID withError:(NSError *)error {
    
}

// Called when the match could not connect to any other players.
- (void)match:(GKMatch *)match didFailWithError:(NSError *)error {
    
}

- (GorillaLayer *)findGorillaWithPlayerID:(NSString *)playerID {

    for (GorillaLayer *gorilla in [GorillasAppDelegate get].gameLayer.gorillas)
        if ([gorilla.playerID isEqualToString:playerID])
            return gorilla;
    
    return nil;
}

@end
