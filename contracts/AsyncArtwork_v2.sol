pragma solidity ^0.5.12;

import "./ERC721.sol";
import "./ERC721Enumerable.sol";
import "./ERC721Metadata.sol";

// interface for the v1 contract
interface AsyncArtwork_v1 {
    function getControlToken(uint256 controlTokenId) external view returns (int256[] memory);

    function tokenURI(uint256 tokenId) external view returns (string memory);
}

// Copyright (C) 2020 Asynchronous Art, Inc.
// GNU General Public License v3.0
// Full notice https://github.com/asyncart/async-contracts/blob/master/LICENSE

contract AsyncArtwork_v2 is Initializable, ERC721, ERC721Enumerable, ERC721Metadata {
    // An event whenever the platform address is updated
    event PlatformAddressUpdated(
        address platformAddress
    );

    event PermissionUpdated(
        uint256 tokenId,
        address tokenOwner,
        address permissioned
    );

    // An event whenever royalty amount for a token is updated
    event PlatformSalePercentageUpdated (
        uint256 tokenId,
        uint256 platformFirstPercentage,
        uint256 platformSecondPercentage        
    );

    // An event whenever artist secondary sale percentage is updated
    event ArtistSecondSalePercentUpdated (
        uint256 artistSecondPercentage
    );

    // An event whenever a bid is proposed
    event BidProposed(
        uint256 tokenId,
        uint256 bidAmount,
        address bidder
    );

    // An event whenever an bid is withdrawn
    event BidWithdrawn(
        uint256 tokenId
    );

    // An event whenever a buy now price has been set
    event BuyPriceSet(
        uint256 tokenId,
        uint256 price
    );

    // An event when a token has been sold 
    event TokenSale(
        // the id of the token
        uint256 tokenId,
        // the price that the token was sold for
        uint256 salePrice,
        // the address of the buyer
        address buyer
    );

    // An event whenever a control token has been updated
    event ControlLeverUpdated(
        // the id of the token
        uint256 tokenId,
        // an optional amount that the updater sent to boost priority of the rendering
        uint256 priorityTip,
        // the ids of the levers that were updated
        uint256[] leverIds,
        // the previous values that the levers had before this update (for clients who want to animate the change)
        int256[] previousValues,
        // the new updated value
        int256[] updatedValues
    );

    // struct for a token that controls part of the artwork
    struct ControlToken {
        // number that tracks how many levers there are
        uint256 numControlLevers;
        // false by default, true once instantiated
        bool exists;
        // false by default, true once setup by the artist
        bool isSetup;
        // the levers that this control token can use
        mapping(uint256 => ControlLever) levers;
    }

    // struct for a lever on a control token that can be changed
    struct ControlLever {
        // // The minimum value this token can have (inclusive)
        int256 minValue;
        // The maximum value this token can have (inclusive)
        int256 maxValue;
        // The current value for this token
        int256 currentValue;
        // false by default, true once instantiated
        bool exists;
    }

    // struct for a pending bid 
    struct PendingBid {
        // the address of the bidder
        address payable bidder;
        // the amount that they bid
        uint256 amount;
        // false by default, true once instantiated
        bool exists;
    }

    // track whether this token was sold the first time or not (used for determining whether to use first or secondary sale percentage)
    mapping(uint256 => bool) public tokenDidHaveFirstSale;
    // if a token's URI has been locked or not
    mapping(uint256 => bool) public tokenURILocked;
    // what tokenId creators are allowed to mint
    mapping(address => uint256) public creatorWhitelist;
    // map control token ID to its buy price
    mapping(uint256 => uint256) public buyPrices;    
    // mapping of addresses to credits for failed transfers
    mapping(address => uint256) public failedTransferCredits;
    // mapping of tokenId to percentage of sale that the platform gets on first sales
    mapping(uint256 => uint256) public platformFirstSalePercentages;
    // mapping of tokenId to percentage of sale that the platform gets on secondary sales
    mapping(uint256 => uint256) public platformSecondSalePercentages;
    // for each token, holds an array of the creator collaborators. For layer tokens it will likely just be [artist], for master tokens it may hold multiples
    mapping(uint256 => address payable[]) public uniqueTokenCreators;    
    // map a control token ID to its highest bid
    mapping(uint256 => PendingBid) public pendingBids;
    // map a control token id to a control token struct
    mapping(uint256 => ControlToken) controlTokenMapping;    
    // mapping of addresses that are allowed to control tokens on your behalf
    mapping(address => mapping(uint256 => address)) public permissionedControllers;
    // the percentage of sale that an artist gets on secondary sales
    uint256 public artistSecondSalePercentage;
    // gets incremented to placehold for tokens not minted yet
    uint256 public expectedTokenSupply;
    // the address of the platform (for receving commissions and royalties)
    address payable public platformAddress;
    // the address of the contract that can upgrade from v1 to v2 tokens
    address public upgraderAddress;

    function initialize(string memory name, string memory symbol, uint256 initialExpectedTokenSupply, address _upgraderAddress) public initializer {
        ERC721.initialize();
        ERC721Enumerable.initialize();
        ERC721Metadata.initialize(name, symbol);

        // starting royalty amounts
        artistSecondSalePercentage = 10;

        // by default, the platformAddress is the address that mints this contract
        platformAddress = msg.sender;

        // set the upgrader address
        upgraderAddress = _upgraderAddress;

        // set the initial expected token supply       
        expectedTokenSupply = initialExpectedTokenSupply;

        require(expectedTokenSupply > 0);
    }

    // modifier for only allowing the platform to make a call
    modifier onlyPlatform() {
        require(msg.sender == platformAddress);
        _;
    }

    modifier onlyWhitelistedCreator(uint256 forTokenId) {
        require(creatorWhitelist[msg.sender] == forTokenId);
        _;
    }

    // reserve a tokenID and layer count for a creator. Define a platform royalty percentage per art piece (some pieces have higher or lower amount)
    function whitelistTokenForCreator(address creator, uint256 forTokenId, uint256 layerCount, 
        uint256 platformFirstSalePercentage, uint256 platformSecondSalePercentage) public onlyPlatform {
        // the tokenID we're reserving must be the current expected token supply
        require(forTokenId == expectedTokenSupply);
        // Async pieces must have at least 1 layer
        require (layerCount > 0);
        // reserve the tokenID for this creator
        creatorWhitelist[creator] = forTokenId;
        // increase the expected token supply
        expectedTokenSupply = forTokenId + layerCount + 1;
        // define the platform percentages for this token here
        platformFirstSalePercentages[forTokenId] = platformFirstSalePercentage;
        platformSecondSalePercentages[forTokenId] = platformSecondSalePercentage;
    }

    // Allows the current platform address to update to something different
    function updatePlatformAddress(address payable newPlatformAddress) public onlyPlatform {
        platformAddress = newPlatformAddress;

        emit PlatformAddressUpdated(newPlatformAddress);
    }

    // Allows platform to waive the first sale requirement for a token (for charity events, special cases, etc)
    function waiveFirstSaleRequirement(uint256 tokenId) public onlyPlatform {
        // This allows the token sale proceeds to go to the current owner (rather than be distributed amongst the token's creators)
        tokenDidHaveFirstSale[tokenId] = true;
    }

    // Allows platform to change the royalty percentage for a specific token
    function updatePlatformSalePercentage(uint256 tokenId, uint256 platformFirstSalePercentage, 
        uint256 platformSecondSalePercentage) public onlyPlatform {
        // set the percentages for this token
        platformFirstSalePercentages[tokenId] = platformFirstSalePercentage;
        platformSecondSalePercentages[tokenId] = platformSecondSalePercentage;
        // emit an event to notify that the platform percent for this token has changed
        emit PlatformSalePercentageUpdated(tokenId, platformFirstSalePercentage, platformSecondSalePercentage);
    }

    // Allow the platform to update a token's URI if it's not locked yet (for fixing tokens post mint process)
    function updateTokenURI(uint256 tokenId, string memory tokenURI) public onlyPlatform {
        // ensure that this token exists
        require(_exists(tokenId));
        // ensure that the URI for this token is not locked yet
        require(tokenURILocked[tokenId] == false);
        // update the token URI
        super._setTokenURI(tokenId, tokenURI);
    }

    // Locks a token's URI from being updated
    function lockTokenURI(uint256 tokenId) public onlyPlatform {
        // ensure that this token exists
        require(_exists(tokenId));
        // lock this token's URI from being changed
        tokenURILocked[tokenId] = true;
    }

    // Allows platform to change the percentage that artists receive on secondary sales
    function updateArtistSecondSalePercentage(uint256 _artistSecondSalePercentage) public onlyPlatform {
        // update the percentage that artists get on secondary sales
        artistSecondSalePercentage = _artistSecondSalePercentage;
        // emit an event to notify that the artist second sale percent has updated
        emit ArtistSecondSalePercentUpdated(artistSecondSalePercentage);
    }

    function setupControlToken(uint256 controlTokenId, string memory controlTokenURI,
        int256[] memory leverMinValues,
        int256[] memory leverMaxValues,
        int256[] memory leverStartValues,
        address payable[] memory additionalCollaborators
    ) public {
        // Hard cap the number of levers a single control token can have
        require (leverMinValues.length <= 500, "Too many control levers.");
        // Hard cap the number of collaborators a single control token can have
        require (additionalCollaborators.length <= 50, "Too many collaborators.");
        // check that a control token exists for this token id
        require(controlTokenMapping[controlTokenId].exists, "No control token found");
        // ensure that this token is not setup yet
        require(controlTokenMapping[controlTokenId].isSetup == false, "Already setup");
        // ensure that only the control token artist is attempting this mint
        require(uniqueTokenCreators[controlTokenId][0] == msg.sender, "Must be control token artist");
        // enforce that the length of all the array lengths are equal
        require((leverMinValues.length == leverMaxValues.length) && (leverMaxValues.length == leverStartValues.length), "Values array mismatch");
        // mint the control token here
        super._safeMint(msg.sender, controlTokenId);
        // set token URI
        super._setTokenURI(controlTokenId, controlTokenURI);        
        // create the control token
        controlTokenMapping[controlTokenId] = ControlToken(leverStartValues.length, true, true);
        // create the control token levers now
        for (uint256 k = 0; k < leverStartValues.length; k++) {
            // enforce that maxValue is greater than or equal to minValue
            require(leverMaxValues[k] >= leverMinValues[k], "Max val must >= min");
            // enforce that currentValue is valid
            require((leverStartValues[k] >= leverMinValues[k]) && (leverStartValues[k] <= leverMaxValues[k]), "Invalid start val");
            // add the lever to this token
            controlTokenMapping[controlTokenId].levers[k] = ControlLever(leverMinValues[k],
                leverMaxValues[k], leverStartValues[k], true);
        }
        // the control token artist can optionally specify additional collaborators on this layer
        for (uint256 i = 0; i < additionalCollaborators.length; i++) {
            // can't provide burn address as collaborator
            require(additionalCollaborators[i] != address(0));

            uniqueTokenCreators[controlTokenId].push(additionalCollaborators[i]);
        }
    }

    // upgrade a token from the v1 contract to this v2 version
    function upgradeV1Token(uint256 artworkTokenId, address v1Address, bool isControlToken, address to, 
        uint256 platformFirstPercentageForToken, uint256 platformSecondPercentageForToken, 
        address payable[] memory uniqueTokenCreatorsForToken) public {
        // get reference to v1 token contract
        AsyncArtwork_v1 v1Token = AsyncArtwork_v1(v1Address);

        // require that only the upgrader address is calling this method
        require(msg.sender == upgraderAddress);

        // preserve the unique token creators
        uniqueTokenCreators[artworkTokenId] = uniqueTokenCreatorsForToken;

        if (isControlToken) {
            // preserve the control token details if it's a control token
            int256[] memory controlToken = v1Token.getControlToken(artworkTokenId);
            
            controlTokenMapping[artworkTokenId] = ControlToken(controlToken.length / 3, true, true);

            for (uint256 k = 0; k < controlToken.length / 3; k++) {
                controlTokenMapping[artworkTokenId].levers[k] = ControlLever(controlToken[k * 3],
                    controlToken[k * 3 + 1], controlToken[k * 3 + 2], true);
            }
        }

        // Set the royalty percentage for this token
        platformFirstSalePercentages[artworkTokenId] = platformFirstPercentageForToken;

        platformSecondSalePercentages[artworkTokenId] = platformSecondPercentageForToken;

        // Mint and transfer the token to the original v1 token owner
        super._safeMint(to, artworkTokenId);

        // set the same token URI
        super._setTokenURI(artworkTokenId, v1Token.tokenURI(artworkTokenId));
    }

    function mintArtwork(uint256 artworkTokenId, string memory artworkTokenURI, address payable[] memory controlTokenArtists)
        public onlyWhitelistedCreator(artworkTokenId) {
        // Can't mint a token with ID 0 anymore
        require(artworkTokenId > 0);
        // Mint the token that represents ownership of the entire artwork    
        super._safeMint(msg.sender, artworkTokenId);
        // reset the creator whitelist
        creatorWhitelist[msg.sender] = 0;
        // set the token URI for this art
        super._setTokenURI(artworkTokenId, artworkTokenURI);
        // track the msg.sender address as the artist address for future royalties
        uniqueTokenCreators[artworkTokenId].push(msg.sender);
        // iterate through all control token URIs (1 for each control token)
        for (uint256 i = 0; i < controlTokenArtists.length; i++) {
            // can't provide burn address as artist
            require(controlTokenArtists[i] != address(0));
            // determine the tokenID for this control token
            uint256 controlTokenId = artworkTokenId + i + 1;
            // add this control token artist to the unique creator list for that control token
            uniqueTokenCreators[controlTokenId].push(controlTokenArtists[i]);
            // stub in an existing control token so exists is true
            controlTokenMapping[controlTokenId] = ControlToken(0, true, false);

            // Layer control tokens use the same royalty percentage as the master token
            platformFirstSalePercentages[controlTokenId] = platformFirstSalePercentages[artworkTokenId];

            platformSecondSalePercentages[controlTokenId] = platformSecondSalePercentages[artworkTokenId];

            if (controlTokenArtists[i] != msg.sender) {
                bool containsControlTokenArtist = false;

                for (uint256 k = 0; k < uniqueTokenCreators[artworkTokenId].length; k++) {
                    if (uniqueTokenCreators[artworkTokenId][k] == controlTokenArtists[i]) {
                        containsControlTokenArtist = true;
                        break;
                    }
                }
                if (containsControlTokenArtist == false) {
                    uniqueTokenCreators[artworkTokenId].push(controlTokenArtists[i]);
                }
            }
        }
    }
    // Bidder functions
    function bid(uint256 tokenId) public payable {
        // don't allow bids of 0
        require(msg.value > 0);
        // don't let owners/approved bid on their own tokens
        require(_isApprovedOrOwner(msg.sender, tokenId) == false);
        // check if there's a high bid
        if (pendingBids[tokenId].exists) {
            // enforce that this bid is higher
            require(msg.value > pendingBids[tokenId].amount, "Bid must be > than current bid");
            // Return bid amount back to bidder
            safeFundsTransfer(pendingBids[tokenId].bidder, pendingBids[tokenId].amount);
        }
        // set the new highest bid
        pendingBids[tokenId] = PendingBid(msg.sender, msg.value, true);
        // Emit event for the bid proposal
        emit BidProposed(tokenId, msg.value, msg.sender);
    }
    // allows an address with a pending bid to withdraw it
    function withdrawBid(uint256 tokenId) public {
        // check that there is a bid from the sender to withdraw (also allows platform address to withdraw a bid on someone's behalf)
        require(pendingBids[tokenId].exists && ((pendingBids[tokenId].bidder == msg.sender) || (msg.sender == platformAddress)));
        // Return bid amount back to bidder
        safeFundsTransfer(pendingBids[tokenId].bidder, pendingBids[tokenId].amount);
        // clear highest bid
        pendingBids[tokenId] = PendingBid(address(0), 0, false);
        // emit an event when the highest bid is withdrawn
        emit BidWithdrawn(tokenId);
    }
    // Buy the artwork for the currently set price
    function takeBuyPrice(uint256 tokenId) public payable {
        // don't let owners/approved buy their own tokens
        require(_isApprovedOrOwner(msg.sender, tokenId) == false);
        // get the sale amount
        uint256 saleAmount = buyPrices[tokenId];
        // check that there is a buy price
        require(saleAmount > 0);
        // check that the buyer sent exact amount to purchase
        require(msg.value == saleAmount);
        // Return all highest bidder's money
        if (pendingBids[tokenId].exists) {
            // Return bid amount back to bidder
            safeFundsTransfer(pendingBids[tokenId].bidder, pendingBids[tokenId].amount);
            // clear highest bid
            pendingBids[tokenId] = PendingBid(address(0), 0, false);
        }
        onTokenSold(tokenId, saleAmount, msg.sender);
    }

    // Take an amount and distribute it evenly amongst a list of creator addresses
    function distributeFundsToCreators(uint256 amount, address payable[] memory creators) private {
        uint256 creatorShare = amount.div(creators.length);

        for (uint256 i = 0; i < creators.length; i++) {
            safeFundsTransfer(creators[i], creatorShare);
        }
    }

    // When a token is sold via list price or bid. Distributes the sale amount to the unique token creators and transfer
    // the token to the new owner
    function onTokenSold(uint256 tokenId, uint256 saleAmount, address to) private {
        // if the first sale already happened, then give the artist + platform the secondary royalty percentage
        if (tokenDidHaveFirstSale[tokenId]) {
            // give platform its secondary sale percentage
            uint256 platformAmount = saleAmount.mul(platformSecondSalePercentages[tokenId]).div(100);
            safeFundsTransfer(platformAddress, platformAmount);
            // distribute the creator royalty amongst the creators (all artists involved for a base token, sole artist creator for layer )
            uint256 creatorAmount = saleAmount.mul(artistSecondSalePercentage).div(100);
            distributeFundsToCreators(creatorAmount, uniqueTokenCreators[tokenId]);
            // cast the owner to a payable address
            address payable payableOwner = address(uint160(ownerOf(tokenId)));
            // transfer the remaining amount to the owner of the token
            safeFundsTransfer(payableOwner, saleAmount.sub(platformAmount).sub(creatorAmount));
        } else {
            tokenDidHaveFirstSale[tokenId] = true;
            // give platform its first sale percentage
            uint256 platformAmount = saleAmount.mul(platformFirstSalePercentages[tokenId]).div(100);
            safeFundsTransfer(platformAddress, platformAmount);
            // this is a token first sale, so distribute the remaining funds to the unique token creators of this token
            // (if it's a base token it will be all the unique creators, if it's a control token it will be that single artist)                      
            distributeFundsToCreators(saleAmount.sub(platformAmount), uniqueTokenCreators[tokenId]);
        }
        // clear highest bid
        pendingBids[tokenId] = PendingBid(address(0), 0, false);
        // Transfer token to msg.sender
        _transferFrom(ownerOf(tokenId), to, tokenId);
        // Emit event
        emit TokenSale(tokenId, saleAmount, to);
    }

    // Owner functions
    // Allow owner to accept the highest bid for a token
    function acceptBid(uint256 tokenId, uint256 minAcceptedAmount) public {
        // check if sender is owner/approved of token        
        require(_isApprovedOrOwner(msg.sender, tokenId));
        // check if there's a bid to accept
        require(pendingBids[tokenId].exists);
        // check that the current pending bid amount is at least what the accepting owner expects
        require(pendingBids[tokenId].amount >= minAcceptedAmount);
        // process the sale
        onTokenSold(tokenId, pendingBids[tokenId].amount, pendingBids[tokenId].bidder);
    }

    // Allows owner of a control token to set an immediate buy price. Set to 0 to reset.
    function makeBuyPrice(uint256 tokenId, uint256 amount) public {
        // check if sender is owner/approved of token        
        require(_isApprovedOrOwner(msg.sender, tokenId));
        // set the buy price
        buyPrices[tokenId] = amount;
        // emit event
        emit BuyPriceSet(tokenId, amount);
    }

    // return the min, max, and current value of a control lever
    function getControlToken(uint256 controlTokenId) public view returns(int256[] memory) {
        require(controlTokenMapping[controlTokenId].exists);

        ControlToken storage controlToken = controlTokenMapping[controlTokenId];

        int256[] memory returnValues = new int256[](controlToken.numControlLevers.mul(3));
        uint256 returnValIndex = 0;

        // iterate through all the control levers for this control token
        for (uint256 i = 0; i < controlToken.numControlLevers; i++) {
            returnValues[returnValIndex] = controlToken.levers[i].minValue;
            returnValIndex = returnValIndex.add(1);

            returnValues[returnValIndex] = controlToken.levers[i].maxValue;
            returnValIndex = returnValIndex.add(1);

            returnValues[returnValIndex] = controlToken.levers[i].currentValue;
            returnValIndex = returnValIndex.add(1);
        }

        return returnValues;
    }

    // anyone can grant permission to another address to control a specific token on their behalf. Set to Address(0) to reset.
    function grantControlPermission(uint256 tokenId, address permissioned) public {
        permissionedControllers[msg.sender][tokenId] = permissioned;

        emit PermissionUpdated(tokenId, msg.sender, permissioned);
    }

    // Allows owner (or permissioned user) of a control token to update its lever values
    // Optionally accept a payment to increase speed of rendering priority
    function useControlToken(uint256 controlTokenId, uint256[] memory leverIds, int256[] memory newValues) public payable {
        // check if sender is owner/approved of token OR if they're a permissioned controller for the token owner      
        require(_isApprovedOrOwner(msg.sender, controlTokenId) || (permissionedControllers[ownerOf(controlTokenId)][controlTokenId] == msg.sender),
            "Owner or permissioned only");
        // collect the previous lever values for the event emit below
        int256[] memory previousValues = new int256[](newValues.length);

        for (uint256 i = 0; i < leverIds.length; i++) {
            // get the control lever
            ControlLever storage lever = controlTokenMapping[controlTokenId].levers[leverIds[i]];

            // Enforce that the new value is valid        
            require((newValues[i] >= lever.minValue) && (newValues[i] <= lever.maxValue), "Invalid val");

            // Enforce that the new value is different
            require(newValues[i] != lever.currentValue, "Must provide different val");

            // grab previous value for the event emit
            int256 previousValue = lever.currentValue;

            // Update token current value
            lever.currentValue = newValues[i];

            // collect the previous lever values for the event emit below
            previousValues[i] = previousValue;
        }

        // if there's a payment then send it to the platform (for higher priority updates)
        if (msg.value > 0) {
            safeFundsTransfer(platformAddress, msg.value);
        }

        // emit event
        emit ControlLeverUpdated(controlTokenId, msg.value, leverIds, previousValues, newValues);
    }

    // Allows a user to withdraw all failed transaction credits
    function withdrawAllFailedCredits() public {
        uint256 amount = failedTransferCredits[msg.sender];

        require(amount != 0);
        require(address(this).balance >= amount);

        failedTransferCredits[msg.sender] = 0;

        msg.sender.transfer(amount);
    }

    // Safely transfer funds and if fail then store that amount as credits for a later pull
    function safeFundsTransfer(address payable recipient, uint256 amount) internal {
        // attempt to send the funds to the recipient
        (bool success, ) = recipient.call.value(amount)("2300");
        // if it failed, update their credit balance so they can pull it later
        if (success == false) {
            failedTransferCredits[recipient] = failedTransferCredits[recipient].add(amount);
        }
    }

    // override the default transfer
    function _transferFrom(address from, address to, uint256 tokenId) internal {
        // clear a buy now price
        buyPrices[tokenId] = 0;
        // transfer the token
        super._transferFrom(from, to, tokenId);
    }
}