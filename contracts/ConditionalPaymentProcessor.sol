pragma solidity ^0.4.24;
import "openzeppelin-solidity/contracts/AddressUtils.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "erc-1155/contracts/IERC1155.sol";
import "./OracleConsumer.sol";

contract ConditionalPaymentProcessor is OracleConsumer, IERC1155 {
    using SafeMath for uint;
    using AddressUtils for address;

    event ConditionPreparation(bytes32 indexed conditionId, address indexed oracle, bytes32 indexed questionId, uint payoutSlotCount);
    event ConditionResolution(bytes32 indexed conditionId, address indexed oracle, bytes32 indexed questionId, uint payoutSlotCount, bytes result);
    event PositionSplit(address indexed stakeholder, ERC20 collateralToken, bytes32 indexed splitSlotId, bytes32 indexed conditionId, uint amount);
    event PositionMerge(address indexed stakeholder, ERC20 collateralToken, bytes32 indexed mergedSlotId, bytes32 indexed conditionId, uint amount);
    event PayoutRedemption(address indexed redeemer, ERC20 indexed collateralToken, bytes32 indexed redeemedSlotId, uint payout);

    /// Mapping key is an conditionId
    mapping(bytes32 => uint[]) public payoutNumerators;
    mapping(bytes32 => uint) public payoutDenominator;

    /// First key is the address of an account holder who has a stake in some payout slot for a condition.
    /// Second key is H(collateralToken . payoutSlotId), where payoutSlotId is made by summing up H(conditionId . index).
    /// The result of the mapping is the amount of stake held in a corresponding payout slot by the account holder, where the stake is backed by collateralToken.
    mapping(address => mapping(bytes32 => uint)) internal positions;

    function prepareCondition(address oracle, bytes32 questionId, uint payoutSlotCount) public {
        bytes32 conditionId = keccak256(abi.encodePacked(oracle, questionId, payoutSlotCount));
        require(payoutNumerators[conditionId].length == 0, "condition already prepared");
        payoutNumerators[conditionId] = new uint[](payoutSlotCount);
        emit ConditionPreparation(conditionId, oracle, questionId, payoutSlotCount);
    }

    function receiveResult(bytes32 questionId, bytes result) external {
        require(result.length > 0, "results empty");
        require(result.length % 32 == 0, "results not 32-byte aligned");
        uint payoutSlotCount = result.length / 32;
        bytes32 conditionId = keccak256(abi.encodePacked(msg.sender, questionId, payoutSlotCount));
        require(payoutNumerators[conditionId].length == payoutSlotCount, "number of outcomes mismatch");
        require(payoutDenominator[conditionId] == 0, "payout denominator already set");
        for(uint i = 0; i < payoutSlotCount; i++) {
            uint payout;
            assembly {
                payout := calldataload(add(0x64, mul(0x20, i)))
            }
            payoutDenominator[conditionId] = payoutDenominator[conditionId].add(payout);

            require(payoutNumerators[conditionId][i] == 0, "payout already set");
            payoutNumerators[conditionId][i] = payout;
        }
        require(payoutDenominator[conditionId] > 0, "payout is all zeroes");
        emit ConditionResolution(conditionId, msg.sender, questionId, payoutSlotCount, result);
    }

    function splitPosition(ERC20 collateralToken, bytes32 splitSlotId, bytes32 conditionId, uint amount) public {
        uint payoutSlotCount = payoutNumerators[conditionId].length;
        require(payoutSlotCount > 0, "condition not prepared yet");

        bytes32 key;
        if(splitSlotId == bytes32(0)) {
            require(collateralToken.transferFrom(msg.sender, this, amount), "could not receive collateral tokens");
        } else {
            key = keccak256(abi.encodePacked(collateralToken, splitSlotId));
            positions[msg.sender][key] = positions[msg.sender][key].sub(amount);
        }

        for(uint i = 0; i < payoutSlotCount; i++) {
            key = keccak256(abi.encodePacked(collateralToken, getPayoutSlotId(splitSlotId, conditionId, i)));
            positions[msg.sender][key] = positions[msg.sender][key].add(amount);
        }
        emit PositionSplit(msg.sender, collateralToken, splitSlotId, conditionId, amount);
    }

    function mergePosition(ERC20 collateralToken, bytes32 mergedSlotId, bytes32 conditionId, uint amount) public {
        uint payoutSlotCount = payoutNumerators[conditionId].length;
        require(payoutSlotCount > 0, "condition not prepared yet");

        bytes32 key;
        for(uint i = 0; i < payoutSlotCount; i++) {
            key = keccak256(abi.encodePacked(collateralToken, getPayoutSlotId(mergedSlotId, conditionId, i)));
            positions[msg.sender][key] = positions[msg.sender][key].sub(amount);
        }

        if(mergedSlotId == bytes32(0)) {
            require(collateralToken.transfer(msg.sender, amount), "could not send collateral tokens");
        } else {
            key = keccak256(abi.encodePacked(collateralToken, mergedSlotId));
            positions[msg.sender][key] = positions[msg.sender][key].add(amount);
        }

        emit PositionMerge(msg.sender, collateralToken, mergedSlotId, conditionId, amount);
    }

    function getPayoutSlotCount(bytes32 conditionId) public view returns (uint) {
        return payoutNumerators[conditionId].length;
    }

    function getPayoutSlotId(bytes32 parentSlotId, bytes32 conditionId, uint index) public pure returns (bytes32) {
        return bytes32(
            uint(parentSlotId) +
            uint(keccak256(abi.encodePacked(conditionId, index)))
        );
    }

    function redeemPayout(ERC20 collateralToken, bytes32 redeemedSlotId, bytes32 conditionId) public {
        require(payoutDenominator[conditionId] > 0, "result for condition not received yet");
        uint totalPayout = 0;
        uint payoutSlotCount = payoutNumerators[conditionId].length;
        require(payoutSlotCount > 0, "condition not prepared yet");
        bytes32 key;
        for(uint i = 0; i < payoutSlotCount; i++) {
            key = keccak256(abi.encodePacked(collateralToken, getPayoutSlotId(redeemedSlotId, conditionId, i)));
            uint payoutNumerator = payoutNumerators[conditionId][i];
            uint payoutStake = positions[msg.sender][key];
            if(payoutStake > 0) {
                totalPayout = totalPayout.add(payoutStake.mul(payoutNumerator).div(payoutDenominator[conditionId]));
                positions[msg.sender][key] = 0;
            }
        }
        if (totalPayout > 0) {
            if(redeemedSlotId == bytes32(0)) {
                require(collateralToken.transfer(msg.sender, totalPayout), "could not transfer payout to message sender");
            } else {
                key = keccak256(abi.encodePacked(collateralToken, redeemedSlotId));
                positions[msg.sender][key] = positions[msg.sender][key].add(totalPayout);
            }
        }
        emit PayoutRedemption(msg.sender, collateralToken, redeemedSlotId, totalPayout);
    }

    mapping (uint256 => mapping(address => mapping(address => uint256))) internal allowances;

    function transferFrom(address _from, address _to, uint256 _id, uint256 _value) external {
        if(_from != msg.sender) {
            allowances[_id][_from][msg.sender] = allowances[_id][_from][msg.sender].sub(_value);
        }

        positions[_from][bytes32(_id)] = positions[_from][bytes32(_id)].sub(_value);
        positions[_to][bytes32(_id)] = _value.add(positions[_to][bytes32(_id)]);

        emit Transfer(msg.sender, _from, _to, _id, _value);
    }

    function safeTransferFrom(address _from, address _to, uint256 _id, uint256 _value, bytes _data) external {
        this.transferFrom(_from, _to, _id, _value);

        require(_checkAndCallSafeTransfer(_from, _to, _id, _value, _data));
    }

    function approve(address _spender, uint256 _id, uint256 _currentValue, uint256 _value) external {
        // if the allowance isn't 0, it can only be updated to 0 to prevent an allowance change immediately after withdrawal
        require(_value == 0 || allowances[_id][msg.sender][_spender] == _currentValue);
        allowances[_id][msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _id, _currentValue, _value);
    }

    function balanceOf(uint256 _id, address _owner) external view returns (uint256) {
        return positions[_owner][bytes32(_id)];
    }

    function allowance(uint256 _id, address _owner, address _spender) external view returns (uint256) {
        return allowances[_id][_owner][_spender];
    }

    bytes4 constant private ERC1155_RECEIVED = 0xf23a6e61;
    function _checkAndCallSafeTransfer(
        address _from,
        address _to,
        uint256 _id,
        uint256 _value,
        bytes _data
    )
    internal
    returns (bool)
    {
        if (!_to.isContract()) {
            return true;
        }
        bytes4 retval = IERC1155TokenReceiver(_to).onERC1155Received(
            msg.sender, _from, _id, _value, _data);
        return (retval == ERC1155_RECEIVED);
    }
}
